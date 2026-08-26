import PDFKit
import UIKit
import UniformTypeIdentifiers
import Vision

final class ShareViewController: UIViewController {
    private let statusLabel = UILabel()
    private let handoffPrefix = "INBOX_PERSONAL_TEAM_V1:"

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let icon = UIImageView(image: UIImage(systemName: "tray.and.arrow.down.fill"))
        icon.tintColor = .label
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 34)
        statusLabel.text = "Wird erkannt …"
        statusLabel.font = .preferredFont(forTextStyle: .headline)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [icon, statusLabel])
        stack.axis = .vertical
        stack.spacing = 18
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24)
        ])

        Task { await importSharedContent() }
    }

    private func importSharedContent() async {
        do {
            let captured = try await captureFirstSupportedItem()
            let payload = PersonalTeamHandoff(
                id: UUID(),
                text: captured.text,
                sourceType: captured.sourceType.rawValue,
                sourceURL: captured.sourceURL?.absoluteString
            )
            let data = try JSONEncoder().encode(payload)
            UIPasteboard.general.string = handoffPrefix + data.base64EncodedString()
            await finish("Erkannt · jetzt Inbox öffnen")
        } catch {
            await finish("Konnte nicht importieren", error: error)
        }
    }

    @MainActor
    private func finish(_ message: String, error: Error? = nil) async {
        statusLabel.text = message
        try? await Task.sleep(nanoseconds: 900_000_000)
        if let error { extensionContext?.cancelRequest(withError: error) }
        else { extensionContext?.completeRequest(returningItems: nil) }
    }

    private func captureFirstSupportedItem() async throws -> CapturedContent {
        guard let extensionItems = extensionContext?.inputItems as? [NSExtensionItem] else { throw ShareError.noSupportedContent }
        let providers = extensionItems.flatMap { $0.attachments ?? [] }

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier), let result = try await capturePDF(provider) { return result }
            if provider.canLoadObject(ofClass: UIImage.self), let result = try await captureImage(provider) { return result }

            if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier), let value = try await loadItem(provider, typeIdentifier: UTType.plainText.identifier) {
                let text = (value as? String) ?? (value as? NSAttributedString)?.string
                if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return CapturedContent(text: text, sourceType: .text, sourceURL: nil)
                }
            }

            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier), let value = try await loadItem(provider, typeIdentifier: UTType.url.identifier) {
                let url = (value as? URL) ?? (value as? NSURL).map { $0 as URL }
                if let url { return CapturedContent(text: url.absoluteString, sourceType: .url, sourceURL: url) }
            }

            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier), let result = try await captureGenericFile(provider) { return result }
        }
        throw ShareError.noSupportedContent
    }

    private func captureImage(_ provider: NSItemProvider) async throws -> CapturedContent? {
        guard let image = try await loadImage(provider) else { return nil }
        return CapturedContent(text: recognizeText(in: image), sourceType: .image, sourceURL: nil)
    }

    private func capturePDF(_ provider: NSItemProvider) async throws -> CapturedContent? {
        guard let value = try await loadItem(provider, typeIdentifier: UTType.pdf.identifier) else { return nil }
        let data: Data?
        if let url = (value as? URL) ?? (value as? NSURL).map({ $0 as URL }) { data = try? Data(contentsOf: url) }
        else if let direct = value as? Data { data = direct }
        else if let nsData = value as? NSData { data = nsData as Data }
        else { data = nil }
        guard let data else { return nil }
        return CapturedContent(text: PDFDocument(data: data)?.string ?? "", sourceType: .pdf, sourceURL: nil)
    }

    private func captureGenericFile(_ provider: NSItemProvider) async throws -> CapturedContent? {
        guard let value = try await loadItem(provider, typeIdentifier: UTType.fileURL.identifier),
              let url = (value as? URL) ?? (value as? NSURL).map({ $0 as URL }) else { return nil }
        return CapturedContent(text: url.lastPathComponent, sourceType: .file, sourceURL: nil)
    }

    private func recognizeText(in image: UIImage) -> String {
        guard let cgImage = image.cgImage else { return "" }
        var lines: [String] = []
        let request = VNRecognizeTextRequest { request, _ in
            lines = (request.results as? [VNRecognizedTextObservation])?.compactMap { $0.topCandidates(1).first?.string } ?? []
        }
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["de-DE", "en-US"]
        try? VNImageRequestHandler(cgImage: cgImage).perform([request])
        return lines.joined(separator: "\n")
    }

    private func loadImage(_ provider: NSItemProvider) async throws -> UIImage? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UIImage?, Error>) in
            provider.loadObject(ofClass: UIImage.self) { object, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: object as? UIImage) }
            }
        }
    }

    private func loadItem(_ provider: NSItemProvider, typeIdentifier: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any?, Error>) in
            provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: item) }
            }
        }
    }
}

private struct PersonalTeamHandoff: Codable {
    let id: UUID
    let text: String
    let sourceType: String
    let sourceURL: String?
}

private struct CapturedContent {
    let text: String
    let sourceType: InboxSourceType
    let sourceURL: URL?
}

private enum ShareError: LocalizedError {
    case noSupportedContent
    var errorDescription: String? { "Dieser Inhalt kann noch nicht übernommen werden." }
}
