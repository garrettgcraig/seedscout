import Foundation
import Observation
import UIKit

/// Persistence for seed lots and their photos.
///
/// Lots are JSON in Application Support; photos are JPEG files beside them.
/// Deliberately not the bundled SQLite database - that ships read-only and is
/// replaced wholesale by an app update, which would take user data with it.
///
/// JSON rather than a second SQLite file because the whole point is
/// interoperability with the web client's export, and the collection is small:
/// a prolific season is a few hundred lots, which encodes in a few milliseconds.
@Observable
@MainActor
final class RecordStore {
    private(set) var lots: [SeedLot] = []
    private(set) var photos: [LotPhoto] = []
    private(set) var loadError: String?

    private let dir: URL
    private let lotsURL: URL
    private let photosURL: URL
    private let imagesDir: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dir = base.appendingPathComponent("SeedScout", isDirectory: true)
        lotsURL = dir.appendingPathComponent("lots.json")
        photosURL = dir.appendingPathComponent("photos.json")
        imagesDir = dir.appendingPathComponent("images", isDirectory: true)
        try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        load()
    }

    // MARK: - Load and save

    private func load() {
        let dec = JSONDecoder()
        if let d = try? Data(contentsOf: lotsURL) {
            lots = (try? dec.decode([SeedLot].self, from: d)) ?? []
        }
        if let d = try? Data(contentsOf: photosURL) {
            photos = (try? dec.decode([LotPhoto].self, from: d)) ?? []
        }
    }

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try enc.encode(lots).write(to: lotsURL, options: .atomic)
            try enc.encode(photos).write(to: photosURL, options: .atomic)
            loadError = nil
        } catch {
            loadError = "Could not save records: \(error.localizedDescription)"
        }
    }

    // MARK: - Lots

    func add(_ lot: SeedLot) {
        lots.insert(lot, at: 0)
        save()
    }

    func update(_ lot: SeedLot) {
        guard let i = lots.firstIndex(where: { $0.id == lot.id }) else { return }
        lots[i] = lot
        save()
    }

    func delete(_ lot: SeedLot) {
        lots.removeAll { $0.id == lot.id }
        for p in photos where p.lotID == lot.id {
            try? FileManager.default.removeItem(at: imagesDir.appendingPathComponent(p.file))
        }
        photos.removeAll { $0.lotID == lot.id }
        save()
    }

    /// Lots whose stratification is due within a week, or already past due.
    var needingAttention: [SeedLot] {
        lots.filter { $0.lifecycle().needsAttention }
            .sorted { ($0.lifecycle().daysLeft ?? 0) < ($1.lifecycle().daysLeft ?? 0) }
    }

    // MARK: - Photos

    func photos(for lot: SeedLot) -> [LotPhoto] {
        let order = PhotoStage.allCases
        return photos.filter { $0.lotID == lot.id }
            .sorted { a, b in
                let ia = order.firstIndex(of: a.stage) ?? 0, ib = order.firstIndex(of: b.stage) ?? 0
                return ia == ib ? a.date < b.date : ia < ib
            }
    }

    func url(for photo: LotPhoto) -> URL { imagesDir.appendingPathComponent(photo.file) }

    /// Downscale and store. Camera images are ~4000 px and several megabytes;
    /// nothing here needs more than 1400.
    @discardableResult
    func addPhoto(_ image: UIImage, to lot: SeedLot, stage: PhotoStage,
                  caption: String? = nil) -> LotPhoto? {
        let maxEdge: CGFloat = 1400
        let scale = min(1, maxEdge / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        let shrunk = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        guard let data = shrunk.jpegData(compressionQuality: 0.82) else { return nil }

        let photo = LotPhoto(lotID: lot.id, stage: stage, date: ISO.string(Date()),
                             caption: caption, file: "\(UUID().uuidString).jpg")
        do {
            try data.write(to: url(for: photo), options: .atomic)
        } catch {
            loadError = "Could not save photo: \(error.localizedDescription)"
            return nil
        }
        photos.append(photo)
        save()
        return photo
    }

    func delete(_ photo: LotPhoto) {
        try? FileManager.default.removeItem(at: url(for: photo))
        photos.removeAll { $0.id == photo.id }
        save()
    }

    // MARK: - Export and import

    /// JSON in the shape the web client writes, so the two interoperate.
    func exportJSON() throws -> Data {
        struct Bundle: Codable {
            let app = "seedscout"
            let schema = 1
            let exported: String
            let records: [SeedLot]
            let photos: [LotPhoto]
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(Bundle(exported: ISO.string(Date()), records: lots, photos: photos))
    }

    /// Merge an export from either surface. Existing ids win, so importing the
    /// same file twice does not duplicate anything.
    @discardableResult
    func importJSON(_ data: Data) throws -> Int {
        struct Bundle: Decodable { let records: [SeedLot] }
        let incoming = try JSONDecoder().decode(Bundle.self, from: data).records
        let known = Set(lots.map(\.id))
        let fresh = incoming.filter { !known.contains($0.id) }
        lots.insert(contentsOf: fresh, at: 0)
        save()
        return fresh.count
    }

    /// CSV with the same columns as the web export, including the signed offset
    /// from the modelled peak - the column that makes these records usable as
    /// calibration data rather than just a diary.
    func exportCSV(peakLookup: (Int?) -> Int?) -> String {
        let cols = ["id", "taxon_id", "species", "common", "date", "lat", "lng",
                    "elevation", "quantity", "notes",
                    "modelled_peak_doy", "days_from_peak",
                    "storage_method", "storage_date", "scarify_method", "scarify_date",
                    "stratify_method", "stratify_start", "stratify_days",
                    "sown_date", "sown_count", "sown_medium", "germ_date", "germ_count",
                    "stratify_end", "germination_rate", "days_to_germination"]

        func esc(_ v: Any?) -> String {
            let s = v.map { "\($0)" } ?? ""
            return "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\""
        }

        var out = [cols.joined(separator: ",")]
        for lot in lots {
            let lc = lot.lifecycle()
            var peak: Int?
            var offset: Int?
            if let p = peakLookup(lot.taxonID), let d = ISO.date(lot.date) {
                peak = p
                let day = DOY.today(d)
                let fwd = DOY.forward(from: p, to: day)
                let back = DOY.forward(from: day, to: p)
                offset = fwd <= back ? fwd : -back
            }
            let p = lot.prop
            out.append([
                esc(lot.id), esc(lot.taxonID), esc(lot.species), esc(lot.common), esc(lot.date),
                esc(lot.lat), esc(lot.lng), esc(lot.elevation), esc(lot.quantity), esc(lot.notes),
                esc(peak), esc(offset),
                esc(p.storage.method), esc(p.storage.date),
                esc(p.scarify.method), esc(p.scarify.date),
                esc(p.stratify.method), esc(p.stratify.start), esc(p.stratify.days),
                esc(p.sown.date), esc(p.sown.count), esc(p.sown.medium),
                esc(p.germ.date), esc(p.germ.count),
                esc(lc.stratEnd.map(ISO.string)),
                esc(lc.rate.map { String(format: "%.3f", $0) }),
                esc(lc.daysToGerminate),
            ].joined(separator: ","))
        }
        return out.joined(separator: "\n")
    }
}
