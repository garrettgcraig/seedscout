import CoreLocation
import SwiftUI

struct SpeciesDetailView: View {
    let fit: Fit
    let day: Int
    /// Where the user is searching from, so the observation map can be centred
    /// and scoped the same way the results list was.
    let centre: CLLocationCoordinate2D
    let radiusKm: Double
    /// The place name shown in Find, used to title the calendar event.
    var placeLabel: String = "Map pin"
    var shareLink: URL? = nil

    @Environment(RecordStore.self) private var records
    @State private var loggingLot: SeedLot?
    @State private var addingToCalendar = false
    @State private var photos: [Photo] = []
    @State private var tips: Tips?
    private let store = try? SpeciesStore()

    var body: some View {
        List {
            if !photos.isEmpty { photoStrip }

            ObservationMap(fit: fit, centre: centre, radiusKm: radiusKm, day: day)

            Section("Timing") {
                TimelineBar(fit: fit, day: day).padding(.vertical, 4)
                LabeledContent("Seed likely ripe",
                               value: "\(DOY.label(fit.ripeStart)) – \(DOY.label(fit.ripeEnd))")
                LabeledContent("Peak", value: DOY.label(fit.ripePeak))
                if let f = fit.flowerPeak {
                    LabeledContent("Flowering peak", value: DOY.label(f))
                }
                if let p = fit.provenance {
                    Label(p, systemImage: "scope").font(.footnote).foregroundStyle(.secondary)
                }
                // Never offered for rare or listed species: they are do-not-collect.
                if !fit.sensitive, RipeWindow.next(for: fit) != nil {
                    Button {
                        addingToCalendar = true
                    } label: {
                        Label("Add ripe window to calendar", systemImage: "calendar.badge.plus")
                    }
                }
            }

            if fit.sensitive {
                Section {
                    Label {
                        Text("This species is rare or listed. Do not collect seed from wild populations.")
                            .font(.footnote.weight(.medium))
                    } icon: {
                        Image(systemName: "hand.raised.fill")
                    }
                    .foregroundStyle(.red)
                }
            }

            if let tips, !tips.isEmpty { tipsSection(tips) }

            Section("Confidence") {
                LabeledContent("Records used", value: "\(fit.nLocal) nearby")
                LabeledContent("Window width", value: "\(fit.ripeDays) days")
                if fit.readsLate {
                    Text("Dried fruit persists on this species long after the seed is ripe, so the "
                         + "modeled window can read late. Judge by the condition of the fruit cluster.")
                    .font(.footnote).foregroundStyle(.secondary)
                }
                if fit.confidence < 0.5 {
                    Text("Few records back this window. Treat it as a rough guide.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .safeAreaInset(edge: .bottom) { logBar }
        .sheet(item: $loggingLot) { AddLotSheet(prefill: $0) }
        .sheet(isPresented: $addingToCalendar) {
            if let window = RipeWindow.next(for: fit) {
                RipeWindowEventSheet(
                    fit: fit, window: window,
                    placeLabel: ["Map pin", "Current location"].contains(placeLabel)
                        ? String(format: "%.3f, %.3f", centre.latitude, centre.longitude) : placeLabel,
                    cue: tips?.cue,
                    link: shareLink ?? URL(string: "https://garrettgcraig.com/seedfinder/")!)
                .ignoresSafeArea()
            }
        }
        .navigationTitle(fit.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard let store else { return }
            async let p = try? await store.photos(for: fit.taxonID)
            async let t = try? await store.tips(for: fit.taxonID)
            photos = await p ?? []
            tips = await t ?? nil
        }
    }

    /// Pinned rather than placed at the end of the list: you are standing at the
    /// plant, and it should not require scrolling past the field notes to reach.
    private var logBar: some View {
        Button {
            var lot = SeedLot(taxonID: fit.taxonID, species: fit.name,
                              common: fit.common, date: ISO.string(Date()))
            lot.lat = centre.latitude
            lot.lng = centre.longitude
            loggingLot = lot
        } label: {
            Label("Log a collection of this species", systemImage: "plus")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
        }
        .buttonStyle(.borderedProminent)
        .tint(Color.seedAccent)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .background(.bar)
    }

    private var photoStrip: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(photos, id: \.url) { photo in
                        VStack(alignment: .leading, spacing: 3) {
                            AsyncImage(url: photo.url) { image in
                                image.resizable().aspectRatio(contentMode: .fill)
                            } placeholder: {
                                Rectangle().fill(.quaternary)
                            }
                            .frame(width: 190, height: 140)
                            .clipShape(RoundedRectangle(cornerRadius: 10))

                            Text(photo.showsFruit ? "In fruit" : "Habit")
                                .font(.caption2.weight(.semibold))
                            // Creative Commons terms require the credit to travel
                            // with the image.
                            Text(photo.attribution)
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .frame(width: 190)
                    }
                }
                .padding(.vertical, 4)
            }
        } footer: {
            Text("Photos from iNaturalist contributors under Creative Commons licenses.")
        }
    }

    private func tipsSection(_ t: Tips) -> some View {
        Section {
            if let cue = t.cue { row("How to tell it is ready", cue, "eye") }
            if let collect = t.collect { row("Collecting", collect, "hand.raised") }
            if let handling = t.handling { row("After collection", handling, "shippingbox") }
            if let caution = t.caution {
                Label { Text(caution).font(.footnote) } icon: {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            }
        } header: {
            Text("Field notes")
        } footer: {
            if let note = t.scopeNote {
                Text("\(note) rather than this species specifically.")
            }
        }
    }

    private func row(_ title: String, _ body: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: icon).font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(body).font(.callout)
        }
        .padding(.vertical, 2)
    }
}
