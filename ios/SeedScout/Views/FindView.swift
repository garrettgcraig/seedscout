import CoreLocation
import MapKit
import SwiftUI

struct FindView: View {
    @State private var model = FindModel()
    @State private var location = LocationProvider()
    @State private var camera: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 34.4160, longitude: -119.6980),
            latitudinalMeters: 60_000, longitudinalMeters: 60_000)
    )
    /// Debounces the map: dragging fires continuously and each move is a query.
    @State private var pendingMove: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            List {
                Section { controls } header: { Text("Where and when") }
                ethics
                ForEach(FindModel.Bucket.allCases) { bucket in
                    if let rows = model.buckets[bucket], !rows.isEmpty {
                        Section {
                            ForEach(rows) { fit in
                                NavigationLink(value: fit) {
                                    SpeciesRow(fit: fit, day: model.dayOfYear)
                                }
                            }
                        } header: {
                            HStack {
                                Text(bucket.rawValue)
                                Spacer()
                                Text("\(rows.count)").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if model.buckets.values.allSatisfy(\.isEmpty) && !model.isLoading {
                    ContentUnavailableView(
                        "Nothing ready here",
                        systemImage: "leaf",
                        description: Text("Try a wider radius, another date, or turn off the native-only filter.")
                    )
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("SeedScout")
            .navigationDestination(for: Fit.self) { SpeciesDetailView(fit: $0, day: model.dayOfYear) }
            .searchable(text: $model.query, prompt: "Find a specific plant")
            .onChange(of: model.query) { scheduleRefresh(delay: .milliseconds(180)) }
            .task { await model.refresh() }
        }
    }

    // MARK: - Controls

    @ViewBuilder private var controls: some View {
        DatePicker("Date", selection: $model.date, displayedComponents: .date)
            .onChange(of: model.date) { scheduleRefresh(delay: .zero) }

        Picker("Within", selection: $model.radiusKm) {
            ForEach([10.0, 25, 50, 100], id: \.self) { Text("\(Int($0)) km").tag($0) }
        }
        .onChange(of: model.radiusKm) { scheduleRefresh(delay: .zero) }

        map

        Toggle("Native species only", isOn: $model.nativesOnly)
            .onChange(of: model.nativesOnly) { scheduleRefresh(delay: .zero) }
        Toggle("Only species at this elevation", isOn: $model.matchElevation)
            .onChange(of: model.matchElevation) { scheduleRefresh(delay: .zero) }
    }

    private var map: some View {
        ZStack(alignment: .topTrailing) {
            MapReader { proxy in
                Map(position: $camera) {
                    Marker("", coordinate: model.coordinate).tint(.seedAccent)
                    MapCircle(center: model.coordinate, radius: model.radiusKm * 1000)
                        .foregroundStyle(Color.seedAccent.opacity(0.10))
                        .stroke(Color.seedAccent, lineWidth: 1)
                }
                .onTapGesture { point in
                    if let c = proxy.convert(point, from: .local) { moveTo(c, recenter: false) }
                }
            }
            .frame(height: 210)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            Button {
                Task { await locateMe() }
            } label: {
                Image(systemName: location.state == .denied ? "location.slash" : "location")
                    .imageScale(.medium)
                    .frame(width: 34, height: 34)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
            .foregroundStyle(location.state == .denied ? .red : Color.accentColor)
            .padding(8)
            .accessibilityLabel("Find my location")
        }
        .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
        .overlay(alignment: .bottomLeading) { coordinateLabel }
    }

    private var coordinateLabel: some View {
        Text(String(format: "%.4f, %.4f", model.coordinate.latitude, model.coordinate.longitude))
            .font(.caption2.monospacedDigit())
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(.regularMaterial, in: Capsule())
            .padding(12)
    }

    private var ethics: some View {
        Section {
            Label {
                Text("Collect only from populations of 30+ plants, never more than 30% of the seed, "
                     + "and never without landowner or agency permission. Species marked rare should "
                     + "not be collected at all.")
                .font(.footnote)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        }
    }

    // MARK: - Actions

    private func moveTo(_ c: CLLocationCoordinate2D, recenter: Bool) {
        model.coordinate = c
        if recenter {
            camera = .region(MKCoordinateRegion(
                center: c,
                latitudinalMeters: model.radiusKm * 2600,
                longitudinalMeters: model.radiusKm * 2600))
        }
        scheduleRefresh(delay: .milliseconds(120))
    }

    private func scheduleRefresh(delay: Duration) {
        pendingMove?.cancel()
        pendingMove = Task {
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            await model.refresh()
        }
    }

    private func locateMe() async {
        do {
            let c = try await location.current()
            moveTo(c, recenter: true)
        } catch {
            // State is already reflected on the button; nothing further to do.
        }
    }
}
