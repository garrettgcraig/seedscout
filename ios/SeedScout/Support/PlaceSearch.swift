import CoreLocation
import Foundation
import MapKit

/// Look up a place by name so you can plan a trip somewhere you are not standing.
///
/// Uses MKLocalSearch rather than the Nominatim endpoint the web client calls.
/// It is the native equivalent, needs no network permission of its own beyond
/// what the app already has, and comes with no usage policy to respect - so the
/// debounce here is purely to avoid wasted work, not to be a good citizen of
/// someone else's free service.
@Observable
@MainActor
final class PlaceSearch {
    struct Result: Identifiable, Hashable {
        let id = UUID()
        let title: String
        let subtitle: String
        let coordinate: CLLocationCoordinate2D

        static func == (a: Result, b: Result) -> Bool { a.id == b.id }
        func hash(into h: inout Hasher) { h.combine(id) }
    }

    private(set) var results: [Result] = []
    private(set) var isSearching = false

    private var task: Task<Void, Never>?

    /// Bias results toward what the user is looking at; a search for "Springfield"
    /// should prefer the one nearby.
    var region: MKCoordinateRegion?

    func search(_ text: String) {
        task?.cancel()
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 3 else {
            results = []
            isSearching = false
            return
        }
        task = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await run(q)
        }
    }

    func clear() {
        task?.cancel()
        results = []
        isSearching = false
    }

    private func run(_ query: String) async {
        isSearching = true
        defer { isSearching = false }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = [.address, .pointOfInterest]
        if let region { request.region = region }

        guard let response = try? await MKLocalSearch(request: request).start(),
              !Task.isCancelled else {
            if !Task.isCancelled { results = [] }
            return
        }

        results = response.mapItems.prefix(5).compactMap { item in
            guard let coord = item.placemark.location?.coordinate else { return nil }
            let title = item.name ?? item.placemark.name ?? query
            return Result(title: title,
                          subtitle: Self.describe(item.placemark, excluding: title),
                          coordinate: coord)
        }
    }

    /// A readable second line, skipping any component already in the title so a
    /// result does not read "Boston, Boston, Massachusetts".
    private static func describe(_ p: MKPlacemark, excluding title: String) -> String {
        [p.locality, p.administrativeArea, p.country]
            .compactMap { $0 }
            .filter { $0 != title }
            .joined(separator: ", ")
    }
}
