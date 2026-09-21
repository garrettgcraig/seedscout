import CoreLocation
import MapKit
import SwiftUI

/// Public sightings independent of the annotated phenology dataset.
///
/// The ranked list answers "is it around here"; this answers "where do I walk".
/// Points are real observation coordinates, not the 25 km occurrence grid the
/// ranking uses, because a 25 km cell is not somewhere you can go.
struct ObservationMap: View {
    let fit: Fit
    let centre: CLLocationCoordinate2D
    let radiusKm: Double
    let day: Int

    @State private var points: [Sighting] = []
    @State private var total: Int?
    @State private var cursor: Int?
    @State private var loadedCount = 0
    @State private var loading = false
    @State private var hasMore = true
    @State private var error: String?
    @State private var loaded = false
    @State private var camera: MapCameraPosition = .automatic

    private struct Page: Decodable {
        let total_results: Int
        let results: [Sighting]
    }
    private struct Sighting: Decodable, Identifiable {
        let id: Int
        let geojson: Geometry?
        struct Geometry: Decodable { let coordinates: [Double] }
        var coordinate: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: geojson!.coordinates[1], longitude: geojson!.coordinates[0])
        }
        var hasCoordinate: Bool {
            guard let c = geojson?.coordinates, c.count >= 2 else { return false }
            return c[0].isFinite && c[1].isFinite
        }
    }

    var body: some View {
        Section {
            ZStack(alignment: .bottomTrailing) {
                Map(position: $camera, interactionModes: [.pan, .zoom]) {
                    // Your position, so the points have something to be near.
                    Annotation("", coordinate: centre) {
                        Circle()
                            .strokeBorder(Color.accentColor, lineWidth: 2.5)
                            .background(Circle().fill(.background))
                            .frame(width: 13, height: 13)
                    }
                    ForEach(points) { p in
                        MapCircle(center: p.coordinate, radius: 110)
                            .foregroundStyle(Color.ripeTint.opacity(0.55))
                            .stroke(Color.ripeTint.opacity(0.8), lineWidth: 0.5)
                    }
                }
                .frame(height: 260)
                .clipShape(RoundedRectangle(cornerRadius: 12))

                if !points.isEmpty {
                    Text("\(points.count) mapped")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(.regularMaterial, in: Capsule())
                        .padding(10)
                }
            }
            .listRowInsets(EdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6))

            if let total {
                Text("\(loadedCount) of \(total) observations loaded").font(.caption)
            }
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            if hasMore {
                Button(loading ? "Loading…" : error == nil ? "Load more observations" : "Retry loading observations") {
                    Task { await load() }
                }.disabled(loading)
            }

            if loaded && points.isEmpty {
                Text("No publicly located observations found within \(Int(radiusKm)) km.")
                .font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("Research-grade observations · any season")
        } footer: {
            if !points.isEmpty {
                // Observation density follows people, so a cluster on a trail is
                // not evidence the plant is commoner there.
                Text("Research-grade observations from all dates; no flower or fruit tag required. Public locations may be approximate. Sightings do not confirm seed readiness or that the plant is still present.")
            }
        }
        .task { if !loaded { await load() } }
    }

    private func load() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        var url = URLComponents(string: "https://api.inaturalist.org/v1/observations")!
        url.queryItems = [
            .init(name: "taxon_id", value: String(fit.taxonID)),
            .init(name: "lat", value: String(centre.latitude)),
            .init(name: "lng", value: String(centre.longitude)),
            .init(name: "radius", value: String(radiusKm)),
            .init(name: "geo", value: "true"),
            .init(name: "quality_grade", value: "research"),
            .init(name: "per_page", value: "100"),
            .init(name: "order_by", value: "id"),
            .init(name: "order", value: "asc"),
        ]
        if let cursor { url.queryItems?.append(.init(name: "id_above", value: String(cursor))) }
        do {
            let request = URLRequest(url: url.url!, timeoutInterval: 20)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            let page = try JSONDecoder().decode(Page.self, from: data)
            if total == nil { total = page.total_results }
            loadedCount += page.results.count
            let known = Set(points.map(\.id))
            points += page.results.filter { $0.hasCoordinate && !known.contains($0.id) }
            cursor = page.results.last?.id ?? cursor
            hasMore = page.results.count == 100 && loadedCount < (total ?? 0)
            error = nil
            loaded = true
        } catch {
            self.error = "Could not load observations. An internet connection is required. \(error.localizedDescription)"
            return
        }
        // Frame the points if there are any, otherwise just show the search area.
        if let region = Self.region(covering: points.map(\.coordinate) + [centre]) {
            camera = .region(region)
        } else {
            camera = .region(MKCoordinateRegion(
                center: centre,
                latitudinalMeters: radiusKm * 2200, longitudinalMeters: radiusKm * 2200))
        }
    }

    private static func region(covering coords: [CLLocationCoordinate2D]) -> MKCoordinateRegion? {
        guard coords.count > 1 else { return nil }
        let lats = coords.map(\.latitude), lngs = coords.map(\.longitude)
        guard let minLat = lats.min(), let maxLat = lats.max(),
              let minLng = lngs.min(), let maxLng = lngs.max() else { return nil }
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2,
                                           longitude: (minLng + maxLng) / 2),
            span: MKCoordinateSpan(latitudeDelta: max((maxLat - minLat) * 1.35, 0.02),
                                   longitudeDelta: max((maxLng - minLng) * 1.35, 0.02)))
    }
}
