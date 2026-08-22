import CoreLocation
import Foundation

/// Why a species search came back empty.
///
/// The four cases below are genuinely different problems with genuinely
/// different fixes, and the app used to collapse all of them into "Nothing ready
/// here - try a wider radius". For a plant that does not grow in your state, or
/// one hidden by a filter, that advice is not merely unhelpful; following it
/// wastes the user's time and makes the tool look broken.
enum SearchOutcome: Equatable {
    /// Matches exist and are shown.
    case found

    /// Nothing in the database matches the text at all.
    case notInDatabase(query: String)

    /// The species exists but has no fruiting records within the radius.
    /// `nearestKm` is the distance to the closest record, when there is one.
    case notNearby(name: String, common: String?, nearestKm: Double?, bearing: String?)

    /// It grows here, but a filter is hiding it.
    case filteredOut(name: String, common: String?, reason: FilterReason)

    /// It grows here and is simply out of season.
    case outOfSeason(name: String, common: String?, ripeStart: Int, ripePeak: Int, daysAway: Int)

    enum FilterReason: Equatable {
        case nonNative
        case elevation(lo: Int, hi: Int, yours: Int)
    }
}

extension SearchOutcome {
    var title: String {
        switch self {
        case .found: return ""
        case .notInDatabase: return "Not in the dataset"
        case .notNearby(let name, let common, _, _): return "\(common?.capitalizedFirst ?? name) isn't recorded near here"
        case .filteredOut(let name, let common, _): return "\(common?.capitalizedFirst ?? name) is hidden by a filter"
        case .outOfSeason(let name, let common, _, _, _): return "\(common?.capitalizedFirst ?? name) isn't in season"
        }
    }

    var message: String {
        switch self {
        case .found:
            return ""
        case .notInDatabase(let q):
            return "No species matching \"\(q)\". The model only covers plants with at least "
                 + "five research-grade fruiting records in the lower 48, so uncommon and "
                 + "rarely-annotated species are missing."
        case .notNearby(_, _, let km, let bearing):
            guard let km else {
                return "No fruiting records for it anywhere in the dataset near your search."
            }
            let dir = bearing.map { " to the \($0)" } ?? ""
            return "The nearest fruiting records are about \(Int(km)) km away\(dir)."
        case .filteredOut(_, _, .nonNative):
            return "It's recorded as introduced here, and the native-only filter is on."
        case .filteredOut(_, _, .elevation(let lo, let hi, let yours)):
            return "It fruits between \(lo) and \(hi) m, and you're at \(yours) m."
        case .outOfSeason(_, _, let start, _, let days):
            return "Seed ripens around \(DOY.label(start)) — about \(days) days from the date you've selected."
        }
    }

    /// A concrete next step the user can take, when one exists.
    var action: Action? {
        switch self {
        case .notNearby: return .widenRadius
        case .filteredOut(_, _, .nonNative): return .showNonNatives
        case .filteredOut(_, _, .elevation): return .ignoreElevation
        case .outOfSeason(_, _, let start, _, _): return .jumpToDate(start)
        default: return nil
        }
    }

    enum Action: Equatable {
        case widenRadius
        case showNonNatives
        case ignoreElevation
        case jumpToDate(Int)

        var label: String {
            switch self {
            case .widenRadius: return "Search a wider area"
            case .showNonNatives: return "Include non-native species"
            case .ignoreElevation: return "Ignore elevation"
            case .jumpToDate(let d): return "Jump to \(DOY.label(d))"
            }
        }
    }
}
