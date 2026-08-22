import SwiftUI

@main
struct SeedFinderApp: App {
    @State private var records = RecordStore()

    init() { Typography.register() }

    var body: some Scene {
        WindowGroup {
            // Above the TabView rather than inside a NavigationStack. As a
            // safeAreaInset the navigation bar sampled its tint and turned the
            // whole header orange; forcing a toolbar colour instead blanked the
            // large title. Sitting above everything avoids both, and matches the
            // web client, where the bar spans the page above the header.
            VStack(spacing: 0) {
                EthicsBar()
                TabView {
                    FindView()
                        .tabItem { Label("Find seed", systemImage: "magnifyingglass") }
                    RecordsView()
                        .tabItem { Label("My records", systemImage: "tray.full") }
                }
            }
            .environment(records)
            .tint(.seedAccent)
        }
    }
}
