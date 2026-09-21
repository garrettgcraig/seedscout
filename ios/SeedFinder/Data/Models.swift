import Foundation

/// A species' fitted collection window in one place, joined with its identity
/// and local abundance. This is the row the results list renders.
struct Fit: Identifiable, Hashable {
    let taxonID: Int
    let name: String
    let common: String?
    let family: String?
    let sensitive: Bool
    let statusCodes: String?

    let ripeStart: Int
    let ripePeak: Int
    let ripeEnd: Int
    let ripeDays: Int
    let fruitStart: Int?
    let fruitEnd: Int?
    let flowerPeak: Int?
    let flowerStart: Int?
    let flowerEnd: Int?

    let persistence: Double?
    let confidence: Double
    let method: String?
    let fitLevel: String
    let nLocal: Int
    let establishment: String?
    let elevLo: Int?
    let elevHi: Int?

    /// Fruiting records in the cells inside the current search radius.
    var localRecords: Int = 0

    var id: Int { taxonID }
    var displayName: String { common?.capitalizedFirst ?? name }
    var isNative: Bool { establishment == "native" }
    var isIntroduced: Bool { establishment == "introduced" }

    /// How local the window is. Anything but `cell` was fitted from a wider area
    /// and can miss a climate gradient, so the UI says which.
    var provenance: String? {
        switch fitLevel {
        case "cell": return nil
        case "block": return "fitted from surrounding area"
        case "area": return "fitted from a wider area"
        default: return "region-wide fit — not local"
        }
    }
}

struct Photo: Hashable {
    let url: URL
    let license: String?
    let credit: String?
    let kind: String

    /// Attribution must travel with the image; these are other people's photos
    /// under Creative Commons terms.
    var attribution: String {
        [credit, license?.uppercased()].compactMap { $0 }.joined(separator: " · ")
    }

    var showsFruit: Bool { kind != "habit" }
}

/// Hand-written field guidance, resolved species -> genus -> family.
struct Tips: Hashable {
    let scope: String?
    let cue: String?
    let collect: String?
    let handling: String?
    let caution: String?

    var isEmpty: Bool { cue == nil && collect == nil && handling == nil && caution == nil }

    var scopeNote: String? {
        switch scope {
        case "species": return nil
        case "genus": return "Guidance for this genus"
        case "family": return "Guidance for this family"
        default: return nil
        }
    }
}

extension String {
    var capitalizedFirst: String {
        guard let f = first else { return self }
        return f.uppercased() + dropFirst()
    }
}
