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
                    if phase == .active { store.reload() }
                }
        }
    }
}

@MainActor
final class InboxStore: ObservableObject {
    @Published private(set) var items: [InboxItem] = []
    @Published var lastError: String?

    init() { reload() }

    func reload() {
        do {
            items = try SharedInboxStore.loadItems().sorted { $0.createdAt > $1.createdAt }
            lastError = nil
        } catch { lastError = error.localizedDescription }
    }

    func items(in bucket: InboxBucket) -> [InboxItem] { items.filter { $0.bucket == bucket } }

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
        items.insert(ContentAnalyzer.analyze(text: text, sourceType: .text), at: 0)
        persist()
    }

    func attachmentURL(for item: InboxItem) -> URL? { SharedInboxStore.attachmentURL(for: item.attachmentRelativePath) }

    private func persist() {
        do { try SharedInboxStore.saveItems(items); lastError = nil }
        catch { lastError = error.localizedDescription }
    }
}

struct ContentView: View {
    @EnvironmentObject private var store: InboxStore
    @State private var selectedItem: InboxItem?

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemGroupedBackground).ignoresSafeArea()
                ScrollView {
                    LazyVStack(spacing: 22) {
                        hero
                        captureCard
                        ForEach(InboxBucket.allCases) { bucket in bucketSection(bucket) }
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 36)
                }
                .refreshable { store.reload() }
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(item: $selectedItem) { item in ItemDetailView(item: item).environmentObject(store) }
            .alert("Inbox", isPresented: Binding(get: { store.lastError != nil }, set: { if !$0 { store.lastError = nil } })) {
                Button("OK", role: .cancel) { store.lastError = nil }
            } message: { Text(store.lastError ?? "") }
        }
    }

    private var hero: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("INBOX").font(.caption.weight(.bold)).tracking(1.8).foregroundStyle(.secondary)
                Text("Was braucht dich?").font(.system(size: 34, weight: .bold, design: .rounded))
                Text(heroSubtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            ZStack {
                Circle().fill(.primary).frame(width: 48, height: 48)
                Text("\(store.items(in: .now).count)").font(.headline.monospacedDigit()).foregroundStyle(Color(.systemBackground))
            }
        }
        .padding(.top, 18)
    }

    private var heroSubtitle: String {
        let count = store.items(in: .now).count
        if count == 0 { return "Gerade ist nichts dringend." }
        return count == 1 ? "1 Sache wartet auf deine Aktion." : "\(count) Sachen warten auf deine Aktion."
    }

    private var captureCard: some View {
        Button { store.captureClipboard() } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14).fill(.thinMaterial).frame(width: 48, height: 48)
                    Image(systemName: "doc.on.clipboard.fill").font(.title3)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Zwischenablage reinwerfen").font(.headline)
                    Text("1 Tipp · Erkennung und Sortierung automatisch").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.down.circle.fill").font(.title2)
            }
            .foregroundStyle(.primary)
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 22).fill(Color(.secondarySystemGroupedBackground)))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func bucketSection(_ bucket: InboxBucket) -> some View {
        let bucketItems = store.items(in: bucket)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(bucket.title, systemImage: bucket.systemImage).font(.headline)
                Spacer()
                Text("\(bucketItems.count)").font(.caption.bold()).foregroundStyle(.secondary).padding(.horizontal, 9).padding(.vertical, 4).background(.thinMaterial, in: Capsule())
            }
            if bucketItems.isEmpty {
                HStack {
                    Image(systemName: "checkmark").foregroundStyle(.secondary)
                    Text(bucket.subtitle).font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 18).fill(Color(.secondarySystemGroupedBackground)))
            } else {
                ForEach(bucketItems) { item in itemCard(item) }
            }
        }
    }

    private func itemCard(_ item: InboxItem) -> some View {
        Button { selectedItem = item } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: item.sourceType.systemImage).foregroundStyle(.secondary)
                    Text(item.title).font(.headline).lineLimit(2).multilineTextAlignment(.leading)
                    Spacer()
                    if item.needsReview { Image(systemName: "questionmark.circle.fill").foregroundStyle(.orange) }
                }
                Text(item.summary).font(.subheadline).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading)
                HStack(spacing: 8) {
                    if let amount = item.amount { chip(amount, "eurosign") }
                    if let due = item.dueDate { chip(due.formatted(date: .abbreviated, time: .omitted), "calendar") }
                    Spacer()
                    Text(item.createdAt.formatted(.relative(presentation: .named))).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .foregroundStyle(.primary)
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 20).fill(Color(.secondarySystemGroupedBackground)))
        }
        .buttonStyle(.plain)
    }

    private func chip(_ title: String, _ icon: String) -> some View {
        Label(title, systemImage: icon).font(.caption.weight(.semibold)).padding(.horizontal, 9).padding(.vertical, 6).background(.thinMaterial, in: Capsule())
    }
}

struct ItemDetailView: View {
    let item: InboxItem
    @EnvironmentObject private var store: InboxStore
    @Environment(\.dismiss) private var dismiss
    @State private var previewURL: URL?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.title).font(.title2.bold())
                        Text(item.summary).foregroundStyle(.secondary)
                    }.padding(.vertical, 6)
                }
                Section("Erkannt") {
                    LabeledContent("Zuordnung", value: item.bucket.title)
                    if let amount = item.amount { LabeledContent("Betrag", value: amount) }
                    if let due = item.dueDate { LabeledContent("Termin", value: due.formatted(date: .long, time: .omitted)) }
                    LabeledContent("Sicherheit", value: "\(Int(item.confidence * 100)) %")
                }
                if !item.originalText.isEmpty {
                    Section("Originaltext") { Text(item.originalText).textSelection(.enabled) }
                }
                Section("Quelle") {
                    Label(item.sourceType.label, systemImage: item.sourceType.systemImage)
                    if let url = item.sourceURL { Link(destination: url) { Label("Link öffnen", systemImage: "safari") } }
                    if let attachment = store.attachmentURL(for: item) {
                        Button { previewURL = attachment } label: { Label("Original öffnen", systemImage: "doc") }
                    }
                }
                Section("Verschieben") {
                    ForEach(InboxBucket.allCases) { bucket in
                        Button { store.move(item, to: bucket); dismiss() } label: { Label(bucket.title, systemImage: bucket.systemImage) }.disabled(bucket == item.bucket)
                    }
                }
                Section {
                    Button(role: .destructive) { store.delete(item); dismiss() } label: { Label("Löschen", systemImage: "trash") }
                }
            }
            .navigationTitle("Eingang")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
            .sheet(isPresented: Binding(get: { previewURL != nil }, set: { if !$0 { previewURL = nil } })) {
                if let previewURL { QuickLookPreview(url: previewURL).ignoresSafeArea() }
            }
        }
    }
}

private struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController(); controller.dataSource = context.coordinator; return controller
    }
    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {}
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}
