import Foundation

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

@main struct BatchRecordsTest {
    static func main() throws {
        let old = """
        {"id":"old-collection","species":"Quercus agrifolia","date":"2026-09-18",
         "qty":"20 seeds","elev":12.5,
         "prop":{"sown":{"count":"10","date":"2026-09-18"},"germ":{"count":"4"}}}
        """
        let source = try JSONDecoder().decode(SeedLot.self, from: Data(old.utf8))
        precondition(source.quantity == "20 seeds" && source.elevation == 12)
        precondition(source.lifecycle().rate == 0.4)
        var scarified = source.treatmentBatch(name: "Scarified", count: 10)
        let control = source.treatmentBatch(name: "Untreated", count: 10)
        scarified.prop.scarify.method = "sandpaper / nick"
        scarified.prop.planted = .init(date: "2026-10-18", count: 4, location: "North bed")
        precondition(scarified.id != control.id && scarified.parentID == source.id)
        precondition(control.prop.scarify.method == nil && source.prop.scarify.method == nil)
        precondition(scarified.prop.sown.count == nil)
        let records = [source, scarified, control]
        let decoded = try JSONDecoder().decode([SeedLot].self, from: JSONEncoder().encode(records))
        precondition(decoded == records)
        let minimal = Data(#"{"id":"minimal","species":"Test","date":"2026-09-18"}"#.utf8)
        let minimalRecord = try JSONDecoder().decode(SeedLot.self, from: minimal)
        precondition(minimalRecord.prop == Propagation())
        print("PASS: legacy decoding, batch isolation, planting details, JSON round-trip")
    }
}
