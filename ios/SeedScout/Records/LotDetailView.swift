import PhotosUI
import SwiftUI

/// One seed lot: the propagation schedule and its photos.
struct LotDetailView: View {
    @Environment(RecordStore.self) private var store
    @State var lot: SeedLot
    @State private var pickerItem: PhotosPickerItem?
    @State private var pickerStage: PhotoStage = .specimen
    @State private var showCamera = false

    var body: some View {
        List {
            Section("Collection") {
                LabeledContent("Species", value: lot.species)
                LabeledContent("Collected", value: lot.date)
                if let e = lot.elevation { LabeledContent("Elevation", value: "\(e) m") }
                if let lat = lot.lat, let lng = lot.lng {
                    LabeledContent("Where", value: String(format: "%.4f, %.4f", lat, lng))
                }
                TextField("Quantity", text: binding(\.quantity))
                TextField("Notes", text: binding(\.notes), axis: .vertical).lineLimit(1...4)
            }

            schedule
            photoSection
        }
        .navigationTitle(lot.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: lot) { store.update(lot) }
        .photosPicker(isPresented: .constant(pickerItem == nil ? false : true),
                      selection: $pickerItem, matching: .images)
    }

    // MARK: - Propagation

    @ViewBuilder private var schedule: some View {
        let lc = lot.lifecycle()

        Section("Storage") {
            Picker("Method", selection: binding(\.prop.storage.method, default: "")) {
                Text("—").tag("")
                ForEach(PropOptions.storage, id: \.self) { Text($0).tag($0) }
            }
            dateRow("Stored", binding(\.prop.storage.date))
        }

        Section("Scarification") {
            Picker("Method", selection: binding(\.prop.scarify.method, default: "")) {
                Text("—").tag("")
                ForEach(PropOptions.scarify, id: \.self) { Text($0).tag($0) }
            }
            dateRow("Done", binding(\.prop.scarify.date))
        }

        Section {
            Picker("Method", selection: binding(\.prop.stratify.method, default: "")) {
                Text("—").tag("")
                ForEach(PropOptions.stratify, id: \.self) { Text($0).tag($0) }
            }
            dateRow("Started", binding(\.prop.stratify.start))
            Stepper(value: intBinding(\.prop.stratify.days), in: 0...365, step: 7) {
                LabeledContent("Duration", value: (lot.prop.stratify.days ?? 0) == 0
                               ? "—" : "\(lot.prop.stratify.days ?? 0) days")
            }
            if let end = lc.stratEnd {
                LabeledContent("Finishes") {
                    Text(ISO.string(end))
                        .foregroundStyle(lc.isOverdue ? .red : (lc.needsAttention ? .orange : .primary))
                        .fontWeight(.semibold)
                }
            }
        } header: {
            Text("Stratification")
        } footer: {
            if let d = lc.daysLeft {
                Text(d > 0 ? "\(d) days to go." : "Finished \(-d) days ago — ready to sow.")
            }
        }

        Section("Sowing") {
            dateRow("Sown", binding(\.prop.sown.date))
            Stepper(value: intBinding(\.prop.sown.count), in: 0...100_000, step: 10) {
                LabeledContent("Seeds sown", value: (lot.prop.sown.count ?? 0) == 0
                               ? "—" : "\(lot.prop.sown.count ?? 0)")
            }
            TextField("Medium", text: binding(\.prop.sown.medium))
        }

        Section {
            dateRow("First germination", binding(\.prop.germ.date))
            Stepper(value: intBinding(\.prop.germ.count), in: 0...100_000, step: 5) {
                LabeledContent("Seedlings", value: (lot.prop.germ.count ?? 0) == 0
                               ? "—" : "\(lot.prop.germ.count ?? 0)")
            }
            if let rate = lc.rate {
                LabeledContent("Germination rate") {
                    Text("\(Int(rate * 100))%").fontWeight(.semibold).foregroundStyle(Color.seedAccent)
                }
                if let d = lc.daysToGerminate {
                    LabeledContent("Days to germinate", value: "\(d)")
                }
            }
        } header: {
            Text("Germination")
        }
    }

    // MARK: - Photos

    @ViewBuilder private var photoSection: some View {
        let shots = store.photos(for: lot)
        Section {
            if !shots.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(shots) { photo in
                            VStack(alignment: .leading, spacing: 3) {
                                if let img = UIImage(contentsOfFile: store.url(for: photo).path) {
                                    Image(uiImage: img).resizable().aspectRatio(contentMode: .fill)
                                        .frame(width: 150, height: 115)
                                        .clipShape(RoundedRectangle(cornerRadius: 9))
                                }
                                Text(photo.stage.label).font(.caption2.weight(.semibold))
                                Text(photo.date).font(.caption2).foregroundStyle(.secondary)
                            }
                            .contextMenu {
                                Button("Delete", role: .destructive) { store.delete(photo) }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Picker("Stage", selection: $pickerStage) {
                ForEach(PhotoStage.allCases) { Text($0.label).tag($0) }
            }
            PhotosPicker(selection: $pickerItem, matching: .images) {
                Label("Add photo", systemImage: "camera")
            }
            .onChange(of: pickerItem) {
                Task {
                    guard let item = pickerItem,
                          let data = try? await item.loadTransferable(type: Data.self),
                          let img = UIImage(data: data) else { return }
                    store.addPhoto(img, to: lot, stage: pickerStage)
                    pickerItem = nil
                }
            }
        } header: {
            Text("Photos")
        } footer: {
            Text("Parent plant, cleaned seed, first pot, seedlings, planted out.")
        }
    }

    // MARK: - Bindings

    private func dateRow(_ label: String, _ text: Binding<String>) -> some View {
        DatePicker(label, selection: Binding(
            get: { ISO.date(text.wrappedValue) ?? Date() },
            set: { text.wrappedValue = ISO.string($0) }
        ), displayedComponents: .date)
    }

    private func binding(_ kp: WritableKeyPath<SeedLot, String?>) -> Binding<String> {
        Binding(get: { lot[keyPath: kp] ?? "" },
                set: { lot[keyPath: kp] = $0.isEmpty ? nil : $0 })
    }

    private func binding(_ kp: WritableKeyPath<SeedLot, String?>, default d: String) -> Binding<String> {
        Binding(get: { lot[keyPath: kp] ?? d },
                set: { lot[keyPath: kp] = $0.isEmpty ? nil : $0 })
    }

    private func intBinding(_ kp: WritableKeyPath<SeedLot, Int?>) -> Binding<Int> {
        Binding(get: { lot[keyPath: kp] ?? 0 },
                set: { lot[keyPath: kp] = $0 == 0 ? nil : $0 })
    }
}
