import SwiftUI

@main
struct GPSTeleportApp: App {
    @StateObject private var spoof = SpoofController()
    @StateObject private var spots = SavedSpots()

    init() {
        PairingStore.importFromDocumentsIfPresent()
    }

    var body: some Scene {
        WindowGroup {
            MapScreen()
                .environmentObject(spoof)
                .environmentObject(spots)
                .onOpenURL { url in
                    // A pairing file shared into the app ("Open in GPS Teleport").
                    try? PairingStore.importFile(at: url)
                }
        }
    }
}
