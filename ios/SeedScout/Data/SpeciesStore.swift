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
        guard let path = Bundle.main.path(forResource: "seedscout_conus", ofType: "sqlite") else {
            throw Database.Failure.cannotOpen("seedscout_conus.sqlite missing from bundle")
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

        return Self.resolve(rows, at: coordinate)
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
}
