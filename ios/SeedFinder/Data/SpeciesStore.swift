import CoreLocation
import Foundation

/// Queries against the bundled species database.
///
/// The search is two questions joined in SQLite rather than in Swift: which
/// occurrence cells fall inside the radius, and what window was fitted for each
/// species found there. Doing the join and the aggregate in the database means
/// one pass over an index instead of decoding several hundred rows into Swift
/// objects and grouping them.
actor SpeciesStore {
    static let cellDegrees = 0.25

    private let db: Database
    private(set) var generated: String?
    private(set) var region: String?

    init() throws {
        guard let path = Bundle.main.path(forResource: "seedfinder_conus", ofType: "sqlite") else {
            throw Database.Failure.cannotOpen("seedfinder_conus.sqlite missing from bundle")
        }
        db = try Database(path: path)
    }

    func loadMetadata() async {
        generated = try? await db.scalar("SELECT value FROM meta WHERE key='generated'")
        region = try? await db.scalar("SELECT value FROM meta WHERE key='region'")
    }

    private static let searchSQL = """
    SELECT f.taxon_id, t.name, t.common, t.family, t.sensitive, t.status_codes,
           f.ripe_start, f.ripe_peak, f.ripe_end, f.ripe_days,
           f.fruit_start, f.fruit_end, f.flower_peak, f.flower_start, f.flower_end,
           f.persistence, f.confidence, f.method, f.fit_level, f.n_local,
           f.establishment, f.elev_lo, f.elev_hi,
           SUM(c.n) AS local_records,
           f.tile_r, f.tile_c
    FROM cell c
    JOIN fit f   ON f.taxon_id = c.taxon_id AND f.tile_r = c.tile_r AND f.tile_c = c.tile_c
    JOIN taxon t ON t.taxon_id = f.taxon_id
    WHERE c.cell_r BETWEEN ? AND ? AND c.cell_c BETWEEN ? AND ?
    GROUP BY f.taxon_id, f.tile_r, f.tile_c
    """

    /// Species with a fitted window whose occurrence cells fall within `radiusKm`.
    func search(near coordinate: CLLocationCoordinate2D, radiusKm: Double) async throws -> [Fit] {
        let cell = Self.cellDegrees
        let span = Int((radiusKm / (111 * cell)).rounded(.up)) + 1
        let r0 = Int(floor(coordinate.latitude / cell))
        let c0 = Int(floor(coordinate.longitude / cell))

        let rows = try await db.query(Self.searchSQL, [
            .int(r0 - span), .int(r0 + span), .int(c0 - span), .int(c0 + span),
        ]) { row -> (Fit, Int, Int) in
            let fit = Fit(
                taxonID: row.int(0), name: row.string(1) ?? "", common: row.string(2),
                family: row.string(3), sensitive: row.bool(4), statusCodes: row.string(5),
                ripeStart: row.int(6), ripePeak: row.int(7), ripeEnd: row.int(8),
                ripeDays: row.int(9),
                fruitStart: row.intOrNil(10), fruitEnd: row.intOrNil(11),
                flowerPeak: row.intOrNil(12), flowerStart: row.intOrNil(13),
                flowerEnd: row.intOrNil(14),
                persistence: row.doubleOrNil(15), confidence: row.double(16),
                method: row.string(17), fitLevel: row.string(18) ?? "region",
                nLocal: row.int(19), establishment: row.string(20),
                elevLo: row.intOrNil(21), elevHi: row.intOrNil(22),
                localRecords: row.int(23)
            )
            return (fit, row.int(24), row.int(25))
        }

        let cells = try await db.query(
            "SELECT taxon_id, cell_r, cell_c FROM cell WHERE cell_r BETWEEN ? AND ? AND cell_c BETWEEN ? AND ?",
            [.int(r0-span), .int(r0+span), .int(c0-span), .int(c0+span)]
        ) { ($0.int(0), $0.int(1), $0.int(2)) }
        let origin = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        var distances: [Int: Double] = [:]
        for (id, r, c) in cells {
            let km = origin.distance(from: CLLocation(latitude: (Double(r)+0.5)*cell,
                longitude: (Double(c)+0.5)*cell)) / 1000
            distances[id] = min(distances[id] ?? .infinity, km)
        }
        return Self.resolve(rows, at: coordinate).map { fit in
            var result = fit
            result.nearestAreaKm = distances[fit.taxonID]
            return result
        }
    }

    /// A species can be fitted in more than one tile inside the radius. Prefer the
    /// tile the query point sits in, then the most local fit, then the largest
    /// local sample - the same rule the web client uses, so the two agree.
    private static func resolve(
        _ rows: [(Fit, Int, Int)], at coordinate: CLLocationCoordinate2D
    ) -> [Fit] {
        let tileDeg = 2.0
        let homeR = Int(floor(coordinate.latitude / tileDeg))
        let homeC = Int(floor(coordinate.longitude / tileDeg))
        let rank = ["cell": 0, "block": 1, "area": 2, "region": 3]

        var best: [Int: (fit: Fit, home: Bool, rank: Int)] = [:]
        best.reserveCapacity(rows.count)
        for (fit, tr, tc) in rows {
            let home = (tr == homeR && tc == homeC)
            let r = rank[fit.fitLevel] ?? 3
            guard let existing = best[fit.taxonID] else {
                best[fit.taxonID] = (fit, home, r)
                continue
            }
            let better = (home && !existing.home)
                || (home == existing.home && r < existing.rank)
                || (home == existing.home && r == existing.rank && fit.nLocal > existing.fit.nLocal)
            if better { best[fit.taxonID] = (fit, home, r) }
        }
        return best.values.map(\.fit)
    }

    /// Full-text species lookup, used by the search field and to attach a species
    /// to a collection record.
    func find(matching text: String, limit: Int = 25) async throws -> [(id: Int, name: String, common: String?)] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }
        // Quote the term so punctuation cannot be read as FTS syntax, then allow
        // a prefix match on the last word.
        let term = "\"\(trimmed.replacingOccurrences(of: "\"", with: ""))\"*"
        return try await db.query(
            """
            SELECT t.taxon_id, t.name, t.common
            FROM taxon_fts f JOIN taxon t ON t.taxon_id = f.rowid
            WHERE taxon_fts MATCH ? ORDER BY rank LIMIT ?
            """,
            [.text(term), .int(limit)]
        ) { ($0.int(0), $0.string(1) ?? "", $0.string(2)) }
    }

    func photos(for taxonID: Int) async throws -> [Photo] {
        try await db.query(
            "SELECT url, license, credit, kind FROM photo WHERE taxon_id = ? ORDER BY ord",
            [.int(taxonID)]
        ) { row -> Photo? in
            guard let raw = row.string(0), let url = URL(string: raw) else { return nil }
            return Photo(url: url, license: row.string(1), credit: row.string(2),
                         kind: row.string(3) ?? "seed-window")
        }.compactMap { $0 }
    }

    func tips(for taxonID: Int) async throws -> Tips? {
        try await db.query(
            """
            SELECT tip_scope, tip_cue, tip_collect, tip_handling, tip_caution
            FROM taxon WHERE taxon_id = ?
            """,
            [.int(taxonID)]
        ) {
            Tips(scope: $0.string(0), cue: $0.string(1), collect: $0.string(2),
                 handling: $0.string(3), caution: $0.string(4))
        }.first.flatMap { $0.isEmpty ? nil : $0 }
    }

    // MARK: - Observation points

    /// Individual fruiting records for one species inside a bounding box.
    ///
    /// The 25 km occurrence grid is what ranking uses, but it is far too coarse
    /// to walk to. These are the coordinates people actually recorded fruit at,
    /// which is what makes a species page answer "where do I go".
    func observations(
        taxonID: Int, near coordinate: CLLocationCoordinate2D, radiusKm: Double,
        seasonDay: Int? = nil, seasonWindow: Int = 45
    ) async throws -> [ObservationPoint] {
        let dLat = radiusKm / 111.0
        let dLng = radiusKm / (111.0 * max(cos(coordinate.latitude * .pi / 180), 0.1))
        let e5 = 100_000.0
        let rows = try await db.query(
            """
            SELECT lat_e5, lng_e5, doy FROM obs
            WHERE taxon_id = ? AND lat_e5 BETWEEN ? AND ? AND lng_e5 BETWEEN ? AND ?
            LIMIT 1200
            """,
            [.int(taxonID),
             .int(Int((coordinate.latitude - dLat) * e5)), .int(Int((coordinate.latitude + dLat) * e5)),
             .int(Int((coordinate.longitude - dLng) * e5)), .int(Int((coordinate.longitude + dLng) * e5))]
        ) { row in
            ObservationPoint(
                coordinate: CLLocationCoordinate2D(
                    latitude: Double(row.int(0)) / e5, longitude: Double(row.int(1)) / e5),
                doy: row.int(2))
        }
        guard let seasonDay else { return rows }
        // Records from the wrong time of year say where the plant grows but not
        // where it was seen carrying fruit now, which is the useful question.
        return rows.filter {
            min(DOY.forward(from: seasonDay, to: $0.doy),
                DOY.forward(from: $0.doy, to: seasonDay)) <= seasonWindow
        }
    }

    /// Distance and rough bearing to the closest fruiting record of a species.
    /// Used to answer "it is not here" with something more useful than a shrug.
    func nearestObservation(
        taxonID: Int, to coordinate: CLLocationCoordinate2D
    ) async throws -> (km: Double, bearing: String)? {
        // Widening rings beat a full scan: most species are found in the first
        // step, and the index makes each ring cheap.
        for degrees in [2.0, 6.0, 15.0, 60.0] {
            let e5 = 100_000.0
            let dLng = degrees / max(cos(coordinate.latitude * .pi / 180), 0.1)
            let rows = try await db.query(
                """
                SELECT lat_e5, lng_e5 FROM obs
                WHERE taxon_id = ? AND lat_e5 BETWEEN ? AND ? AND lng_e5 BETWEEN ? AND ?
                LIMIT 4000
                """,
                [.int(taxonID),
                 .int(Int((coordinate.latitude - degrees) * e5)), .int(Int((coordinate.latitude + degrees) * e5)),
                 .int(Int((coordinate.longitude - dLng) * e5)), .int(Int((coordinate.longitude + dLng) * e5))]
            ) { (Double($0.int(0)) / e5, Double($0.int(1)) / e5) }

            var best: (Double, Double, Double)? = nil
            for (lat, lng) in rows {
                let d = Self.haversineKm(coordinate.latitude, coordinate.longitude, lat, lng)
                if best == nil || d < best!.0 { best = (d, lat, lng) }
            }
            if let best {
                return (best.0, Self.compass(from: coordinate, toLat: best.1, lng: best.2))
            }
        }
        return nil
    }

    /// Any fit for this species anywhere, so a miss can tell the difference
    /// between "not in the dataset" and "not around here".
    func anyFit(taxonID: Int) async throws -> Fit? {
        try await db.query(
            """
            SELECT f.taxon_id, t.name, t.common, t.family, t.sensitive, t.status_codes,
                   f.ripe_start, f.ripe_peak, f.ripe_end, f.ripe_days,
                   f.fruit_start, f.fruit_end, f.flower_peak, f.flower_start, f.flower_end,
                   f.persistence, f.confidence, f.method, f.fit_level, f.n_local,
                   f.establishment, f.elev_lo, f.elev_hi
            FROM fit f JOIN taxon t ON t.taxon_id = f.taxon_id
            WHERE f.taxon_id = ? ORDER BY f.n_local DESC LIMIT 1
            """,
            [.int(taxonID)]
        ) { row in
            Fit(taxonID: row.int(0), name: row.string(1) ?? "", common: row.string(2),
                family: row.string(3), sensitive: row.bool(4), statusCodes: row.string(5),
                ripeStart: row.int(6), ripePeak: row.int(7), ripeEnd: row.int(8),
                ripeDays: row.int(9), fruitStart: row.intOrNil(10), fruitEnd: row.intOrNil(11),
                flowerPeak: row.intOrNil(12), flowerStart: row.intOrNil(13),
                flowerEnd: row.intOrNil(14), persistence: row.doubleOrNil(15),
                confidence: row.double(16), method: row.string(17),
                fitLevel: row.string(18) ?? "region", nLocal: row.int(19),
                establishment: row.string(20), elevLo: row.intOrNil(21),
                elevHi: row.intOrNil(22), localRecords: 0)
        }.first
    }

    static func haversineKm(_ a: Double, _ b: Double, _ c: Double, _ d: Double) -> Double {
        let R = 6371.0, r = Double.pi / 180
        let dp = (c - a) * r, dl = (d - b) * r
        let x = sin(dp / 2) * sin(dp / 2)
              + cos(a * r) * cos(c * r) * sin(dl / 2) * sin(dl / 2)
        return 2 * R * asin(min(1, sqrt(x)))
    }

    static func compass(from: CLLocationCoordinate2D, toLat: Double, lng: Double) -> String {
        let dy = toLat - from.latitude
        let dx = (lng - from.longitude) * cos(from.latitude * .pi / 180)
        let angle = atan2(dx, dy) * 180 / .pi
        let names = ["north", "north-east", "east", "south-east",
                     "south", "south-west", "west", "north-west"]
        let idx = Int(((angle + 360).truncatingRemainder(dividingBy: 360) + 22.5) / 45) % 8
        return names[idx]
    }
}

/// One recorded fruiting observation.
struct ObservationPoint: Identifiable, Hashable {
    let coordinate: CLLocationCoordinate2D
    let doy: Int
    var id: String { "\(coordinate.latitude),\(coordinate.longitude),\(doy)" }

    static func == (a: ObservationPoint, b: ObservationPoint) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

}
