import CoreLocation
import MapKit
import SwiftUI

/// Where this species has actually been recorded carrying fruit.
///
/// The ranked list answers "is it around here"; this answers "where do I walk".
/// Points are real observation coordinates, not the 25 km occurrence grid the
/// ranking uses, because a 25 km cell is not somewhere you can go.
struct ObservationMap: View {
    let fit: Fit
    let centre: CLLocationCoordinate2D
    let radiusKm: Double
    let day: Int

    @State private var points: [ObservationPoint] = []
    @State private var seasonOnly = true
    @State private var loaded = false
    @State private var camera: MapCameraPosition = .automatic

    private let store = try? SpeciesStore()

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
                    Text("\(points.count) record\(points.count == 1 ? "" : "s")")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(.regularMaterial, in: Capsule())
                        .padding(10)
                }
            }
            .listRowInsets(EdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6))

            Toggle("Only records from this time of year", isOn: $seasonOnly)
                .font(.callout)
                .onChange(of: seasonOnly) { Task { await load() } }

            if loaded && points.isEmpty {
                Text(seasonOnly
                     ? "No fruiting records within \(Int(radiusKm)) km at this time of year. Turn the filter off to see records from any season."
                     : "No fruiting records within \(Int(radiusKm)) km.")
                .font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("Where it has been found in fruit")
        } footer: {
            if !points.isEmpty {
                // Observation density follows people, so a cluster on a trail is
                // not evidence the plant is commoner there.
                Text("Each dot is a research-grade iNaturalist record of this species in fruit. "
                     + "Records follow where people go, so trails and roadsides are over-represented.")
            }
        }
        .task { await load() }
    }

    private func load() async {
        guard let store else { return }
        points = (try? await store.observations(
            taxonID: fit.taxonID, near: centre, radiusKm: radiusKm,
            seasonDay: seasonOnly ? day : nil)) ?? []
        loaded = true
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
