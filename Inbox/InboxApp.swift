import Combine
import QuickLook
import SwiftUI
import UIKit

@main
struct InboxApp: App {
    @StateObject private var store = InboxStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        store.importPendingShareHandoff()
                        store.reload()
                    }
                }
        }
    }
}

@MainActor
final class InboxStore: ObservableObject {
    @Published private(set) var items: [InboxItem] = []
    @Published var lastError: String?

    private let handoffPrefix = "INBOX_PERSONAL_TEAM_V1:"
    private let lastHandoffKey = "InboxLastPersonalTeamHandoffID"
    private let analyzerVersionKey = "InboxAnalyzerVersion"
    private let analyzerVersion = 3

    init() {
        reload()
        refreshOldAnalysisIfNeeded()
        importPendingShareHandoff()
    }

    func reload() {
        do {
            items = try SharedInboxStore.loadItems().sorted { $0.createdAt > $1.createdAt }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func items(in bucket: InboxBucket) -> [InboxItem] {
        items.filter { $0.bucket == bucket }
    }

    func move(_ item: InboxItem, to bucket: InboxBucket) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[i].bucket = bucket
        items[i].needsReview = false
        persist()
    }

    func delete(_ item: InboxItem) {
        items.removeAll { $0.id == item.id }
        persist()
    }

    func captureClipboard() {
        guard let text = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            lastError = "In der Zwischenablage ist gerade kein Text."
            return
        }
        if text.hasPrefix(handoffPrefix) {
            importPendingShareHandoff()
            return
        }
        items.insert(ContentAnalyzer.analyze(text: text, sourceType: .text), at: 0)
        persist()
    }

    func importPendingShareHandoff() {
        guard let raw = UIPasteboard.general.string, raw.hasPrefix(handoffPrefix) else { return }
        let encoded = String(raw.dropFirst(handoffPrefix.count))
        guard let data = Data(base64Encoded: encoded),
              let payload = try? JSONDecoder().decode(PersonalTeamHandoff.self, from: data) else { return }

        let id = payload.id.uuidString
        guard UserDefaults.standard.string(forKey: lastHandoffKey) != id else { return }

        let sourceType = InboxSourceType(rawValue: payload.sourceType) ?? .text
        let sourceURL = payload.sourceURL.flatMap(URL.init(string:))
        let item = ContentAnalyzer.analyze(text: payload.text, sourceType: sourceType, sourceURL: sourceURL)
        items.insert(item, at: 0)
        UserDefaults.standard.set(id, forKey: lastHandoffKey)
        persist()
    }

    func attachmentURL(for item: InboxItem) -> URL? {
        SharedInboxStore.attachmentURL(for: item.attachmentRelativePath)
    }

    private func refreshOldAnalysisIfNeeded() {
        guard UserDefaults.standard.integer(forKey: analyzerVersionKey) < analyzerVersion else { return }
        guard !items.isEmpty else {
            UserDefaults.standard.set(analyzerVersion, forKey: analyzerVersionKey)
            return
        }

        items = items.map { old in
            guard !old.originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return old }
            var refreshed = ContentAnalyzer.analyze(
                text: old.originalText,
                sourceType: old.sourceType,
                sourceURL: old.sourceURL,
                attachmentRelativePath: old.attachmentRelativePath,
                now: old.createdAt
            )
            refreshed.id = old.id
            refreshed.createdAt = old.createdAt
            return refreshed
        }
        persist()
        UserDefaults.standard.set(analyzerVersion, forKey: analyzerVersionKey)
    }

    private func persist() {
        do {
            try SharedInboxStore.saveItems(items)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }
}

private struct PersonalTeamHandoff: Codable {
    let id: UUID
    let text: String
    let sourceType: String
    let sourceURL: String?
}

struct ContentView: View {
    @EnvironmentObject private var store: InboxStore
    @State private var selectedItem: InboxItem?
    @State private var showArchive = false

    private var attentionItems: [InboxItem] {
        let endTomorrow = Calendar.current.date(byAdding: .day, value: 2, to: Calendar.current.startOfDay(for: Date())) ?? Date()
        return store.items(in: .now).filter { item in
            guard let due = item.dueDate else { return true }
            return due < endTomorrow
        }
    }

    private var upcomingItems: [InboxItem] {
        let endTomorrow = Calendar.current.date(byAdding: .day, value: 2, to: Calendar.current.startOfDay(for: Date())) ?? Date()
        let futureNow = store.items(in: .now).filter { item in
            guard let due = item.dueDate else { return false }
            return due >= endTomorrow
        }
        return (futureNow + store.items(in: .later)).sorted {
            ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture)
        }
    }

    private var waitingItems: [InboxItem] { store.items(in: .waiting) }
    private var archiveItems: [InboxItem] { store.items(in: .archive) }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemGroupedBackground).ignoresSafeArea()
                ScrollView {
                    LazyVStack(spacing: 24) {
                        header
                        captureBar

                        assistantSection(
                            title: "Braucht dich",
                            subtitle: attentionItems.isEmpty ? "Nichts Akutes." : "Das solltest du als Nächstes ansehen.",
                            icon: "sparkles",
                            items: attentionItems
                        )

                        if !upcomingItems.isEmpty {
                            assistantSection(
                                title: "Demnächst",
                                subtitle: "Schon erkannt, aber noch nicht akut.",
                                icon: "calendar.badge.clock",
                                items: upcomingItems
                            )
                        }

                        if !waitingItems.isEmpty {
                            assistantSection(
                                title: "Warten",
                                subtitle: "Hier ist gerade jemand anderes dran.",
                                icon: "hourglass",
                                items: waitingItems
                            )
                        }

                        archiveRow
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 40)
                }
                .refreshable { store.reload() }
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(item: $selectedItem) { item in
                ItemDetailView(item: item).environmentObject(store)
            }
            .sheet(isPresented: $showArchive) {
                ArchiveView(items: archiveItems).environmentObject(store)
            }
            .alert("Inbox", isPresented: Binding(get: { store.lastError != nil }, set: { if !$0 { store.lastError = nil } })) {
                Button("OK", role: .cancel) { store.lastError = nil }
            } message: {
                Text(store.lastError ?? "")
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("INBOX")
                        .font(.caption.weight(.bold))
                        .tracking(1.8)
                        .foregroundStyle(.secondary)
                    Text("Was braucht dich?")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                }
                Spacer()
                ZStack {
                    Circle().fill(.primary).frame(width: 48, height: 48)
                    Text("\(attentionItems.count)")
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(Color(.systemBackground))
                }
            }
            Text(statusText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 18)
    }

    private var statusText: String {
        if attentionItems.isEmpty && upcomingItems.isEmpty && waitingItems.isEmpty {
            return "Alles ruhig. Neue Dinge kannst du einfach über Teilen an Inbox schicken."
        }
        if attentionItems.count == 1 { return "1 Sache braucht deine Aufmerksamkeit." }
        if attentionItems.count > 1 { return "\(attentionItems.count) Sachen brauchen deine Aufmerksamkeit." }
        return "Nichts Akutes. Ich behalte den Rest im Blick."
    }

    private var captureBar: some View {
        Button { store.captureClipboard() } label: {
            HStack(spacing: 12) {
                Image(systemName: "plus")
                    .font(.headline)
                    .frame(width: 34, height: 34)
                    .background(.thinMaterial, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("Schnell hinzufügen").font(.subheadline.weight(.semibold))
                    Text("Text aus der Zwischenablage").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)
            }
            .foregroundStyle(.primary)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 18).fill(Color(.secondarySystemGroupedBackground)))
        }
        .buttonStyle(.plain)
    }

    private func assistantSection(title: String, subtitle: String, icon: String, items: [InboxItem]) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Label(title, systemImage: icon).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(items.count)")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(.thinMaterial, in: Capsule())
            }

            if items.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.secondary)
                    Text("Hier ist gerade nichts zu tun.").font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 20).fill(Color(.secondarySystemGroupedBackground)))
            } else {
                ForEach(items) { item in
                    itemCard(item)
                }
            }
        }
    }

    private func itemCard(_ item: InboxItem) -> some View {
        Button { selectedItem = item } label: {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(.thinMaterial)
                        .frame(width: 46, height: 46)
                    Image(systemName: (item.kind ?? .general).systemImage)
                        .font(.title3)
                }

                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(item.title)
                            .font(.headline)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 8)
                        if item.needsReview {
                            Image(systemName: "questionmark.circle.fill").foregroundStyle(.orange)
                        }
                    }

                    if !item.summary.isEmpty {
                        Text(item.summary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }

                    HStack(spacing: 8) {
                        if let due = item.dueDate { chip(dueText(due), "calendar") }
                        if let amount = item.amount { chip(amount, "eurosign") }
                        Spacer()
                        Image(systemName: item.sourceType.systemImage)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .foregroundStyle(.primary)
            .padding(15)
            .background(RoundedRectangle(cornerRadius: 22).fill(Color(.secondarySystemGroupedBackground)))
        }
        .buttonStyle(.plain)
    }

    private var archiveRow: some View {
        Button { showArchive = true } label: {
            HStack {
                Label("Ablage", systemImage: "archivebox")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(archiveItems.count)").foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)
            }
            .foregroundStyle(.primary)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
    }

    private func chip(_ title: String, _ icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(.thinMaterial, in: Capsule())
    }

    private func dueText(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Heute" }
        if calendar.isDateInTomorrow(date) { return "Morgen" }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}

struct ArchiveView: View {
    let items: [InboxItem]
    @EnvironmentObject private var store: InboxStore
    @Environment(\.dismiss) private var dismiss
    @State private var selectedItem: InboxItem?

    var body: some View {
        NavigationStack {
            List(items) { item in
                Button { selectedItem = item } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title).font(.headline).foregroundStyle(.primary)
                        Text(item.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .overlay {
                if items.isEmpty { ContentUnavailableView("Ablage ist leer", systemImage: "archivebox") }
            }
            .navigationTitle("Ablage")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
            .sheet(item: $selectedItem) { item in
                ItemDetailView(item: item).environmentObject(store)
            }
        }
    }
}

struct ItemDetailView: View {
    let item: InboxItem
    @EnvironmentObject private var store: InboxStore
    @Environment(\.dismiss) private var dismiss
    @State private var previewURL: URL?
    @State private var showRawText = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(alignment: .top, spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 15)
                                .fill(.thinMaterial)
                                .frame(width: 48, height: 48)
                            Image(systemName: (item.kind ?? .general).systemImage)
                                .font(.title3)
                        }
                        VStack(alignment: .leading, spacing: 5) {
                            Text(item.title)
                                .font(.title3.bold())
                            if !item.summary.isEmpty {
                                Text(item.summary)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            if item.needsReview {
                                Label("Bitte kurz prüfen", systemImage: "questionmark.circle")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }

                Section("Erkannt") {
                    if let merchant = item.merchant {
                        compactFact(icon: "building.2", label: "Worum geht es", value: merchant)
                    }

                    HStack(spacing: 16) {
                        compactColumn(label: "Typ", value: (item.kind ?? .general).label)
                        Divider()
                        compactColumn(label: "Status", value: item.bucket.title)
                    }
                    .padding(.vertical, 3)

                    if item.amount != nil || item.dueDate != nil {
                        HStack(spacing: 16) {
                            if let amount = item.amount {
                                compactColumn(label: "Betrag", value: amount)
                            }
                            if item.amount != nil && item.dueDate != nil { Divider() }
                            if let due = item.dueDate {
                                compactColumn(label: "Fällig", value: due.formatted(.dateTime.day().month(.wide).year()))
                            }
                        }
                        .padding(.vertical, 3)
                    }

                    if let service = item.service {
                        compactFact(icon: "creditcard", label: "Dienst", value: service)
                    }
                }

                Section("Quelle") {
                    HStack {
                        Label(item.sourceType.label, systemImage: item.sourceType.systemImage)
                        Spacer()
                        if let attachment = store.attachmentURL(for: item) {
                            Button("Original") { previewURL = attachment }
                                .buttonStyle(.borderless)
                        }
                    }
                    if let url = item.sourceURL {
                        Link(destination: url) { Label("Link öffnen", systemImage: "safari") }
                    }
                    if !item.originalText.isEmpty {
                        DisclosureGroup("Erkannten Text anzeigen", isExpanded: $showRawText) {
                            Text(item.originalText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .padding(.top, 8)
                        }
                    }
                }

                Section("Falls ich falsch lag") {
                    ForEach(InboxBucket.allCases) { bucket in
                        Button {
                            store.move(item, to: bucket)
                            dismiss()
                        } label: {
                            Label(bucket.title, systemImage: bucket.systemImage)
                        }
                        .disabled(bucket == item.bucket)
                    }
                }

                Section {
                    Button(role: .destructive) {
                        store.delete(item)
                        dismiss()
                    } label: {
                        Label("Löschen", systemImage: "trash")
                    }
                }
            }
            .navigationTitle("Eingang")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
            .sheet(isPresented: Binding(get: { previewURL != nil }, set: { if !$0 { previewURL = nil } })) {
                if let previewURL { QuickLookPreview(url: previewURL).ignoresSafeArea() }
            }
        }
    }

    private func compactFact(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.body.weight(.semibold))
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    private func compactColumn(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.body.weight(.semibold)).lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {}

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}
