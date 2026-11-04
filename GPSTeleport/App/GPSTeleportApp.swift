import SwiftUI

@main
struct GPSTeleportApp: App {
    @StateObject private var spoof = SpoofController()
    @StateObject private var spots = SavedSpots()
    @StateObject private var refresher = AppRefresher()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        PairingStore.importFromDocumentsIfPresent()
    }

    var body: some Scene {
        WindowGroup {
            MapScreen()
                .environmentObject(spoof)
                .environmentObject(spots)
                .environmentObject(refresher)
                .onOpenURL { url in
                    // A pairing file shared into the app ("Open in GPS Teleport").
                    try? PairingStore.importFile(at: url)
                }
                .task { didBecomeActive() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                // GPSTeleport-Pairing.exe may have dropped a file in while the app was in the background.
                PairingStore.importFromDocumentsIfPresent()
                didBecomeActive()
            }
        }
    }

    private func didBecomeActive() {
        Task { await AppExpiry.scheduleReminders() }
        refresher.refreshAutomaticallyIfNeeded { [spoof] in
            spoof.isActive || spoof.isBusy
        }
    }
}
