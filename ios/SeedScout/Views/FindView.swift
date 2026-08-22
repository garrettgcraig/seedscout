import CoreLocation
import MapKit
import SwiftUI

struct FindView: View {
    @State private var model = FindModel()
    @State private var location = LocationProvider()
    @State private var places = PlaceSearch()
    @State private var placeQuery = ""
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
                    emptyState
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("SeedScout")
            .navigationDestination(for: Fit.self) {
                SpeciesDetailView(fit: $0, day: model.dayOfYear,
                                  centre: model.coordinate, radiusKm: model.radiusKm)
            }
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

        placeField
        map

        Toggle("Native species only", isOn: $model.nativesOnly)
            .onChange(of: model.nativesOnly) { scheduleRefresh(delay: .zero) }
        Toggle("Only species at this elevation", isOn: $model.matchElevation)
            .onChange(of: model.matchElevation) { scheduleRefresh(delay: .zero) }
    }

    @ViewBuilder private var placeField: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("City, park, or address", text: $placeQuery)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onChange(of: placeQuery) { places.search(placeQuery) }
                .onSubmit { if let first = places.results.first { go(to: first) } }
            if !placeQuery.isEmpty {
                Button {
                    placeQuery = ""
                    places.clear()
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }

        ForEach(places.results) { r in
            Button { go(to: r) } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(r.title).foregroundStyle(.primary)
                    if !r.subtitle.isEmpty {
                        Text(r.subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func go(to result: PlaceSearch.Result) {
        placeQuery = result.title
        places.clear()
        moveTo(result.coordinate, recenter: true)
    }

    private var map: some View {
        ZStack(alignment: .topTrailing) {
            MapReader { proxy in
                Map(position: $camera) {
                    // Spelled out rather than `.seedAccent`: Marker's tint resolves
                    // against ShapeStyle, which cannot see a Color extension.
                    Marker("", coordinate: model.coordinate).tint(Color.seedAccent)
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


    // MARK: - Actions

    private func moveTo(_ c: CLLocationCoordinate2D, recenter: Bool) {
        model.coordinate = c
        // Keep place results biased to wherever the user is now looking.
        places.region = MKCoordinateRegion(center: c, latitudinalMeters: 200_000,
                                           longitudinalMeters: 200_000)
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

    /// What to show when nothing came back. The message names the actual reason
    /// and, where there is one, offers the single control that would fix it.
    @ViewBuilder private var emptyState: some View {
        switch model.outcome {
        case .found:
            ContentUnavailableView(
                "Nothing ready here",
                systemImage: "leaf",
                description: Text("No species are in their collection window at this date and place. "
                                  + "Try another date, or a wider radius."))
        default:
            VStack(spacing: 12) {
                Image(systemName: iconName)
                    .font(.largeTitle).foregroundStyle(.secondary)
                Text(model.outcome.title).font(.headline).multilineTextAlignment(.center)
                Text(model.outcome.message)
                    .font(.footnote).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                if let action = model.outcome.action {
                    Button(action.label) { Task { await model.apply(action) } }
                        .buttonStyle(.borderedProminent).controlSize(.regular)
                        .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .listRowBackground(Color.clear)
        }
    }

    private var iconName: String {
        switch model.outcome {
        case .notInDatabase: return "questionmark.circle"
        case .notNearby: return "location.slash"
        case .filteredOut: return "line.3.horizontal.decrease.circle"
        case .outOfSeason: return "calendar"
        case .found: return "leaf"
        }
    }

}
