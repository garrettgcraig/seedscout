import CoreLocation
import Foundation

/// A seed lot, from the plant it came off to what came up in the pot.
///
/// Field names mirror the web client's record shape so a JSON export from either
/// surface imports into the other. Anything renamed here has to be renamed there.
struct SeedLot: Identifiable, Codable, Hashable {
    var id: String = UUID().uuidString
    var taxonID: Int?
    var species: String            // scientific name, the join key across surfaces
    var common: String?
    var date: String               // ISO yyyy-MM-dd, collection date
    var lat: Double?
    var lng: Double?
    var elevation: Int?
    var quantity: String?
    var notes: String?
    var prop = Propagation()

    enum CodingKeys: String, CodingKey {
        case id, species, common, date, lat, lng, elevation, quantity, notes, prop
        case taxonID = "taxon_id"
    }

    var coordinate: CLLocationCoordinate2D? {
        guard let lat, let lng else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }

    var displayName: String { common?.capitalizedFirst ?? species }
}

struct Propagation: Codable, Hashable {
    var storage = Storage()
    var scarify = Treatment()
    var stratify = Stratification()
    var sown = Sowing()
    var germ = Germination()

    struct Storage: Codable, Hashable {
        var method: String?
        var date: String?
    }
    struct Treatment: Codable, Hashable {
        var method: String?
        var date: String?
    }
    struct Stratification: Codable, Hashable {
        var method: String?
        var start: String?
        var days: Int?
    }
    struct Sowing: Codable, Hashable {
        var date: String?
        var count: Int?
        var medium: String?
    }
    struct Germination: Codable, Hashable {
        var date: String?
        var count: Int?
    }
}

// The same option lists the web client offers, so a value round-trips.
enum PropOptions {
    static let storage = ["paper bag, cool + dry", "sealed, refrigerated", "sealed, frozen",
                          "open tray, drying", "other"]
    static let scarify = ["none needed", "sandpaper / nick", "hot water soak", "acid",
                          "smoke / charate", "other"]
    static let stratify = ["none needed", "cold-moist", "warm-moist", "cold-dry",
                           "warm then cold", "other"]
}

/// Photo stages, ordered as the lot progresses.
enum PhotoStage: String, Codable, CaseIterable, Identifiable {
    case specimen, seed, sown, seedling, planted
    var id: String { rawValue }

    var label: String {
        switch self {
        case .specimen: return "Parent plant"
        case .seed: return "Cleaned seed"
        case .sown: return "First pot"
        case .seedling: return "Seedlings"
        case .planted: return "Planted out"
        }
    }
}

struct LotPhoto: Identifiable, Codable, Hashable {
    var id: String = UUID().uuidString
    var lotID: String
    var stage: PhotoStage
    var date: String
    var caption: String?
    /// Filename inside the photos directory. Images are files, not database
    /// blobs, so the store stays small and the OS can purge thumbnails.
    var file: String
}

// MARK: - Derived state

/// What is happening to this lot right now, computed rather than stored so it
/// cannot go stale.
struct Lifecycle {
    enum Stage: Hashable {
        case collected
        case scarified(String)
        case stratifying(daysLeft: Int, ends: Date)
        case readyToSow(since: Int)
        case sown(String)
        case germinated(rate: Double, days: Int)
    }

    var stages: [Stage] = []
    var stratEnd: Date?
    var daysLeft: Int?
    var rate: Double?
    var daysToGerminate: Int?

    /// Stratification is the step that gets missed, because it falls due months
    /// after the work that starts it.
    var needsAttention: Bool {
        guard let daysLeft else { return false }
        return daysLeft <= 7
    }

    var isOverdue: Bool { (daysLeft ?? 1) <= 0 }
}

extension SeedLot {
    func lifecycle(today: Date = Date()) -> Lifecycle {
        var lc = Lifecycle()
        lc.stages.append(.collected)

        if let m = prop.scarify.method, m != "none needed" {
            lc.stages.append(.scarified(m))
        }

        let st = prop.stratify
        if let m = st.method, m != "none needed", let start = ISO.date(st.start), let days = st.days {
            let end = Calendar.current.date(byAdding: .day, value: days, to: start) ?? start
            lc.stratEnd = end
            let left = Calendar.current.dateComponents([.day], from: today, to: end).day ?? 0
            lc.daysLeft = left
            if prop.sown.date == nil {
                lc.stages.append(left > 0 ? .stratifying(daysLeft: left, ends: end)
                                          : .readyToSow(since: -left))
            }
        }

        if let sownDate = prop.sown.date {
            lc.stages.append(.sown(sownDate))
            let sown = prop.sown.count ?? 0
            let up = prop.germ.count ?? 0
            if let gDate = ISO.date(prop.germ.date), let sDate = ISO.date(sownDate), sown > 0 {
                lc.rate = Double(up) / Double(sown)
                lc.daysToGerminate = Calendar.current.dateComponents([.day], from: sDate, to: gDate).day
                lc.stages.append(.germinated(rate: lc.rate!, days: lc.daysToGerminate ?? 0))
            }
        }
        return lc
    }
}

/// ISO yyyy-MM-dd helpers. Dates are stored as strings so they survive a JSON
/// round trip to the web client unchanged.
enum ISO {
    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func string(_ d: Date) -> String { formatter.string(from: d) }

    static func date(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        return formatter.date(from: s)
    }
}
