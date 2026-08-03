import CoreLocation
import Foundation
import Observation

/// State behind the Find tab: where you are, when, and what that yields.
@Observable
@MainActor
final class FindModel {
    enum Bucket: String, CaseIterable, Identifiable {
        case now = "Collectible now"
        case soon = "Coming up"
        case past = "Just missed"
        var id: String { rawValue }
    }

    var coordinate = CLLocationCoordinate2D(latitude: 34.4160, longitude: -119.6980)
    var date = Date()
    var radiusKm: Double = 25
    var nativesOnly = true
    var matchElevation = true
    var elevation: Int?
    var query = ""

    private(set) var buckets: [Bucket: [Fit]] = [:]
    private(set) var isLoading = false
    private(set) var loadError: String?
    private(set) var speciesCount = 0

    private let store: SpeciesStore?
    private var generation = 0

    init() {
        store = try? SpeciesStore()
        if store == nil {
            loadError = "Species database could not be opened."
        }
    }

    var dayOfYear: Int { DOY.today(date) }

    func refresh() async {
        guard let store else { return }
        generation += 1
        let mine = generation
        isLoading = true
        defer { if mine == generation { isLoading = false } }

        do {
            let fits = try await store.search(near: coordinate, radiusKm: radiusKm)
            // A newer request started while this one was in flight; its results
            // are the ones the user is waiting for.
            guard mine == generation else { return }
            speciesCount = fits.count
            buckets = Self.group(fits, day: dayOfYear, nativesOnly: nativesOnly,
                                 elevation: matchElevation ? elevation : nil,
                                 query: query)
            loadError = nil
        } catch {
            guard mine == generation else { return }
            loadError = error.localizedDescription
        }
    }

    static func group(
        _ fits: [Fit], day: Int, nativesOnly: Bool, elevation: Int?, query: String
    ) -> [Bucket: [Fit]] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        var out: [Bucket: [(Fit, Double)]] = [:]

        for fit in fits {
            if fit.isTooVagueToShow { continue }
            // Introduced weeds dominate observation density near towns, so the
            // default view hides them. Unknown establishment is kept: it usually
            // means a native that simply lacks a listing.
            if nativesOnly && fit.isIntroduced { continue }
            if let elevation, let lo = fit.elevLo, let hi = fit.elevHi {
                // Allow a margin so a species is not hidden from someone standing
                // just outside its recorded band.
                let margin = 250
                if elevation < lo - margin || elevation > hi + margin { continue }
            }
            if !needle.isEmpty {
                let hay = "\(fit.name) \(fit.common ?? "")".lowercased()
                if !hay.contains(needle) { continue }
            }

            let bucket: Bucket
            switch fit.readiness(on: day) {
            case .now: bucket = .now
            case .soon(let days): if days > 45 { continue }; bucket = .soon
            case .past(let days): if days > 21 { continue }; bucket = .past
            }
            out[bucket, default: []].append((fit, fit.score(on: day, localRecords: fit.localRecords)))
        }

        return out.mapValues { pairs in
            pairs.sorted { $0.1 > $1.1 }.prefix(60).map(\.0)
        }
    }
}
