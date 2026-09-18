import CoreLocation
import SwiftUI
import PhotosUI

/// Start a lot. Reached either from the plus button or, far more usefully, from
/// a species page while you are standing at the plant - in which case almost
/// everything here is already filled in.
struct AddLotSheet: View {
    @Environment(RecordStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var prefill: SeedLot?

    @State private var species = ""
    @State private var common: String?
    @State private var taxonID: Int?
    @State private var date = Date()
    @State private var quantity = ""
    @State private var notes = ""
    @State private var coordinate: CLLocationCoordinate2D?
    @State private var elevation: Int?
    @State private var matches: [(id: Int, name: String, common: String?)] = []
    @State private var location = LocationProvider()
    @State private var locationMessage = "No location selected"
    @State private var photoItem: PhotosPickerItem?
    @State private var specimen: UIImage?
    @State private var showCamera = false
    @State private var photoBusy = false
    @State private var saveMessage: String?
    @State private var savedLot: SeedLot?
    @State private var didPrefill = false

    private let lookup = try? SpeciesStore()

    var body: some View {
        NavigationStack {
            Form {
                Section("Species") {
                    TextField("Scientific or common name", text: $species)
                        .autocorrectionDisabled()
                        .onChange(of: species) { Task { await suggest() } }
                    ForEach(matches, id: \.id) { m in
                        Button {
                            species = m.name; common = m.common; taxonID = m.id; matches = []
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(m.common?.capitalizedFirst ?? m.name).foregroundStyle(.primary)
                                Text(m.name).font(.caption).italic().foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("Collection") {
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                    TextField("Quantity (e.g. one paper bag)", text: $quantity)
                    if let c = coordinate {
                        LabeledContent("Where",
                                       value: String(format: "%.4f, %.4f", c.latitude, c.longitude))
                    }
                    Text(locationMessage).font(.caption).foregroundStyle(.secondary)
                    Button("Use my GPS", systemImage: "location") {
                        Task {
                            do {
                                coordinate = try await location.current(precise: true)
                                elevation = nil
                                locationMessage = "Current GPS location"
                            } catch {
                                locationMessage = "Location unavailable. You can save now and add it later."
                            }
                        }
                    }.disabled(location.state == .locating)
                    if let c = prefill?.coordinate {
                        Button("Use search map pin") { coordinate = c; locationMessage = "Search map pin" }
                    }
                    if let e = elevation { LabeledContent("Elevation", value: "\(e) m") }
                    TextField("Notes", text: $notes, axis: .vertical).lineLimit(1...5)
                }

                Section("Parent plant photo") {
                    if let specimen {
                        Image(uiImage: specimen).resizable().scaledToFit().frame(maxHeight: 180)
                        Button("Remove photo", role: .destructive) { self.specimen = nil }
                    }
                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        Button("Take photo", systemImage: "camera") { showCamera = true }
                    }
                    PhotosPicker("Choose photo", selection: $photoItem, matching: .images)
                        .onChange(of: photoItem) {
                            photoBusy = true
                            Task {
                                defer { photoBusy = false }
                                guard let data = try? await photoItem?.loadTransferable(type: Data.self),
                                      let image = UIImage(data: data) else {
                                    saveMessage = "Could not read that photo. Please choose it again."; return
                                }
                                specimen = image
                            }
                        }
                }
                if let saveMessage { Text(saveMessage).foregroundStyle(.red) }

                Section {
                    Text("Take from populations of 30+ plants, never more than 30% of the seed, "
                         + "and only with permission.")
                    .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Log a collection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(species.trimmingCharacters(in: .whitespaces).isEmpty || photoBusy)
                }
            }
            .onAppear(perform: applyPrefill)
            .sheet(isPresented: $showCamera) { SpecimenCamera { specimen = $0 } }
        }
    }

    private func applyPrefill() {
        guard !didPrefill else { return }
        didPrefill = true
        guard let p = prefill else { return }
        species = p.species
        common = p.common
        taxonID = p.taxonID
        // A search centre is not necessarily the plant's collection location.
        if let d = ISO.date(p.date) { date = d }
    }

    private func suggest() async {
        guard let lookup, taxonID == nil || species.count < 3 else { matches = []; return }
        matches = (try? await lookup.find(matching: species, limit: 6)) ?? []
    }

    private func save() {
        var lot = savedLot ?? SeedLot(taxonID: taxonID,
                          species: species.trimmingCharacters(in: .whitespaces),
                          common: common,
                          date: ISO.string(date))
        lot.lat = coordinate?.latitude
        lot.lng = coordinate?.longitude
        lot.elevation = elevation
        lot.quantity = quantity.isEmpty ? nil : quantity
        lot.notes = notes.isEmpty ? nil : notes
        if savedLot == nil {
            store.add(lot)
            guard store.loadError == nil else { saveMessage = store.loadError; return }
            savedLot = lot
        } else {
            store.update(lot)
            guard store.loadError == nil else { saveMessage = store.loadError; return }
        }
        if let specimen, store.addPhoto(specimen, to: lot, stage: .specimen) == nil {
            saveMessage = store.loadError ?? "Collection saved, but photo failed. Tap Save to retry."
            return
        }
        dismiss()
    }
}

struct SpecimenCamera: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss
    let onPhoto: (UIImage) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: SpecimenCamera
        init(_ parent: SpecimenCamera) { self.parent = parent }
        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onPhoto(image) }
            parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}
