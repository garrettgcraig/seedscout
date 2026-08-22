import SwiftUI

@main
struct SeedScoutApp: App {
    @State private var records = RecordStore()

    var body: some Scene {
        WindowGroup {
            TabView {
                FindView()
                    .tabItem { Label("Find seed", systemImage: "magnifyingglass") }
                RecordsView()
                    .tabItem { Label("My records", systemImage: "tray.full") }
            }
            .environment(records)
            .tint(.seedAccent)
        }
    }
}
