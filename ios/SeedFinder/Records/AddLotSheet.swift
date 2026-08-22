import CoreLocation
import SwiftUI

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
                    if let e = elevation { LabeledContent("Elevation", value: "\(e) m") }
                    TextField("Notes", text: $notes, axis: .vertical).lineLimit(1...5)
                }

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
                        .disabled(species.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear(perform: applyPrefill)
        }
    }

    private func applyPrefill() {
        guard let p = prefill else { return }
        species = p.species
        common = p.common
        taxonID = p.taxonID
        coordinate = p.coordinate
        elevation = p.elevation
        if let d = ISO.date(p.date) { date = d }
    }

    private func suggest() async {
        guard let lookup, taxonID == nil || species.count < 3 else { matches = []; return }
        matches = (try? await lookup.find(matching: species, limit: 6)) ?? []
    }

    private func save() {
        var lot = SeedLot(taxonID: taxonID,
                          species: species.trimmingCharacters(in: .whitespaces),
                          common: common,
                          date: ISO.string(date))
        lot.lat = coordinate?.latitude
        lot.lng = coordinate?.longitude
        lot.elevation = elevation
        lot.quantity = quantity.isEmpty ? nil : quantity
        lot.notes = notes.isEmpty ? nil : notes
        store.add(lot)
        dismiss()
    }
}
