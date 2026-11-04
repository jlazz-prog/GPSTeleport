import SwiftUI

@main
struct GPSTeleportApp: App {
    @StateObject private var spoof = SpoofController()
    @StateObject private var spots = SavedSpots()
    @Environment(\.scenePhase) private var scenePhase

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
        .onChange(of: scenePhase) { _, phase in
            // GPSTeleport-Pairing.exe may have dropped a file in while the app was in the background.
            if phase == .active {
                PairingStore.importFromDocumentsIfPresent()
                Task { await AppExpiry.scheduleReminders() }
            }
        }
    }
}
