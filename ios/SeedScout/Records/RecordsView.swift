import CoreLocation
import SwiftUI
import UniformTypeIdentifiers

struct RecordsView: View {
    @Environment(RecordStore.self) private var store
    @State private var showingAdd = false
    @State private var exportDoc: TextDocument?
    @State private var exportKind: UTType = .commaSeparatedText
    @State private var importing = false
    @State private var importNote: String?

    var body: some View {
        NavigationStack {
            List {
                if !store.needingAttention.isEmpty { attention }

                if store.lots.isEmpty {
                    ContentUnavailableView(
                        "No records yet",
                        systemImage: "leaf",
                        description: Text("Find a species that's ready and tap "
                                          + "\"Log a collection\" to start a lot.")
                    )
                } else {
                    Section("Lots") {
                        ForEach(store.lots) { lot in
                            NavigationLink(value: lot) { LotRow(lot: lot) }
                        }
                        .onDelete { idx in idx.map { store.lots[$0] }.forEach(store.delete) }
                    }
                }

                if let note = importNote {
                    Section { Text(note).font(.footnote).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("My records")
            .navigationDestination(for: SeedLot.self) { LotDetailView(lot: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button("Export CSV") { exportCSV() }
                        Button("Export JSON") { exportJSON() }
                        Divider()
                        Button("Import from web export…") { importing = true }
                    } label: { Image(systemName: "square.and.arrow.up") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingAdd = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showingAdd) { AddLotSheet() }
            .fileExporter(isPresented: .constant(exportDoc != nil), document: exportDoc,
                          contentType: exportKind,
                          defaultFilename: "seedscout-records") { _ in exportDoc = nil }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                guard case .success(let url) = result else { return }
                // A file returned by the picker lives outside the sandbox.
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url),
                   let n = try? store.importJSON(data) {
                    importNote = n == 0 ? "Nothing new to import." : "Imported \(n) lot\(n == 1 ? "" : "s")."
                } else {
                    importNote = "That file could not be read as a SeedScout export."
                }
            }
        }
    }

    private var attention: some View {
        Section {
            ForEach(store.needingAttention) { lot in
                let lc = lot.lifecycle()
                NavigationLink(value: lot) {
                    HStack {
                        Image(systemName: lc.isOverdue ? "exclamationmark.circle.fill" : "clock.fill")
                            .foregroundStyle(lc.isOverdue ? .red : .orange)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(lot.displayName).font(.subheadline.weight(.semibold))
                            Text(lc.isOverdue
                                 ? "Stratification finished — ready to sow"
                                 : "Stratification ends in \(lc.daysLeft ?? 0) days")
                            .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text("Needs attention")
        } footer: {
            Text("Stratification finishes months after it starts, which is exactly why it gets missed.")
        }
    }

    private func exportCSV() {
        exportKind = .commaSeparatedText
        exportDoc = TextDocument(text: store.exportCSV(peakLookup: { _ in nil }),
                                 type: .commaSeparatedText)
    }

    private func exportJSON() {
        guard let data = try? store.exportJSON(), let s = String(data: data, encoding: .utf8) else { return }
        exportKind = .json
        exportDoc = TextDocument(text: s, type: .json)
    }
}

private struct LotRow: View {
    let lot: SeedLot

    var body: some View {
        let lc = lot.lifecycle()
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(lot.displayName).font(.headline)
                Spacer()
                Text(lot.date).font(.caption).foregroundStyle(.secondary)
            }
            Text(lot.species).font(.caption).italic().foregroundStyle(.secondary)
            FlowRow(spacing: 5) {
                ForEach(Array(lc.stages.enumerated()), id: \.offset) { _, stage in
                    stageTag(stage)
                }
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private func stageTag(_ s: Lifecycle.Stage) -> some View {
        switch s {
        case .collected:                 Tag("collected", .accent)
        case .scarified(let m):          Tag("scarified: \(m)", .accent)
        case .stratifying(let d, _):     Tag("stratifying · \(d) d left", .warn)
        case .readyToSow(let since):     Tag(since > 0 ? "ready to sow · \(since) d ago" : "ready to sow", .alert)
        case .sown(let d):               Tag("sown \(d)", .accent)
        case .germinated(let rate, _):   Tag("\(Int(rate * 100))% germination", .accent)
        }
    }
}

/// Minimal wrapper so fileExporter can write plain text.
struct TextDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText, .json, .plainText] }
    var text: String
    var type: UTType

    init(text: String, type: UTType) { self.text = text; self.type = type }

    init(configuration: ReadConfiguration) throws {
        text = String(data: configuration.file.regularFileContents ?? Data(), encoding: .utf8) ?? ""
        type = .plainText
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
