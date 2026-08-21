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
    /// Why a search came back empty, so the UI can say something true.
    private(set) var outcome: SearchOutcome = .found
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
            outcome = buckets.values.contains(where: { !$0.isEmpty })
                ? .found
                : await diagnose(fits: fits)
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

    /// Work out *why* a search found nothing.
    ///
    /// Only runs on an empty result, so the extra queries never slow the common
    /// path. The order matters: each check rules out a cheaper explanation
    /// before reaching for a more expensive one.
    private func diagnose(fits: [Fit]) async -> SearchOutcome {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty, let store else { return .found }

        // 1. Does anything in the whole database match the text? This is the
        //    FTS index, which is why it costs well under a millisecond.
        guard let hit = try? await store.find(matching: needle, limit: 1).first else {
            return .notInDatabase(query: needle)
        }

        // 2. It exists. Is it among the species found near this point?
        guard let local = fits.first(where: { $0.taxonID == hit.id }) else {
            let nearest = try? await store.nearestObservation(taxonID: hit.id, to: coordinate)
            return .notNearby(name: hit.name, common: hit.common,
                              nearestKm: nearest?.km, bearing: nearest?.bearing)
        }

        // 3. It is nearby, so a filter or the calendar is hiding it.
        if nativesOnly && local.isIntroduced {
            return .filteredOut(name: local.name, common: local.common, reason: .nonNative)
        }
        if matchElevation, let here = elevation, let lo = local.elevLo, let hi = local.elevHi,
           here < lo - 250 || here > hi + 250 {
            return .filteredOut(name: local.name, common: local.common,
                                reason: .elevation(lo: lo, hi: hi, yours: here))
        }
        let days: Int
        switch local.readiness(on: dayOfYear) {
        case .soon(let d): days = d
        case .past(let d): days = DOY.year - d
        case .now: days = 0
        }
        return .outOfSeason(name: local.name, common: local.common,
                            ripeStart: local.ripeStart, ripePeak: local.ripePeak,
                            daysAway: days)
    }

    /// Apply the fix a `SearchOutcome.Action` describes.
    func apply(_ action: SearchOutcome.Action) async {
        switch action {
        case .widenRadius:
            radiusKm = radiusKm >= 100 ? 100 : (radiusKm == 50 ? 100 : (radiusKm == 25 ? 50 : 25))
        case .showNonNatives:
            nativesOnly = false
        case .ignoreElevation:
            matchElevation = false
        case .jumpToDate(let doy):
            var c = DateComponents(); c.year = Calendar.current.component(.year, from: date); c.day = doy
            if let d = Calendar.current.date(from: c) { date = d }
        }
        await refresh()
    }

}
