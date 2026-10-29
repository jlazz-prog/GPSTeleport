import SwiftUI
import UniformTypeIdentifiers

struct SetupScreen: View {
    @EnvironmentObject private var spoof: SpoofController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var hasPairing = PairingStore.exists
    @State private var vpnLooksOn = LocalDevVPN.isConnected
    @State private var showImporter = false
    @State private var pairingMessage: String?
    @State private var testState: TestState = .idle

    private enum TestState {
        case idle, running(String), passed, failed(String)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    step(done: nil, title: "1. Developer Mode on",
                         detail: "Settings → Privacy & Security → Developer Mode → On. Your iPhone restarts once.")
                }

                Section {
                    step(done: vpnLooksOn, title: "2. LocalDevVPN connected",
                         detail: vpnLooksOn
                            ? "Looks connected."
                            : "Open LocalDevVPN and tap Connect. Be on Wi-Fi the first time you spoof.")
                    Button("Check again") { vpnLooksOn = LocalDevVPN.isConnected }
                }

                Section {
                    step(done: hasPairing, title: "3. Pairing file imported",
                         detail: hasPairing
                            ? "Imported. You only need a new one after an iOS update or reset."
                            : "A one-time file made on your PC that lets this app talk to your iPhone.")
                    Button(hasPairing ? "Replace pairing file…" : "Import pairing file…") { showImporter = true }
                    Button("Paste pairing file from clipboard") { pasteFromClipboard() }
                    if hasPairing {
                        Button("Remove pairing file", role: .destructive) {
                            PairingStore.remove()
                            hasPairing = false
                        }
                    }
                    if let pairingMessage {
                        Text(pairingMessage).font(.caption).foregroundStyle(.secondary)
                    }
                    DisclosureGroup("How do I get a pairing file?") {
                        Text("""
                        On your PC:
                        1. Install the free Apple Devices app from the Microsoft Store.
                        2. Download GPSTeleport-Pairing.exe from the same GitHub release page as this app.
                        3. Plug in your iPhone, unlock it, and run GPSTeleport-Pairing.exe. Tap Trust if your iPhone asks.
                        4. Come back here: this step turns green by itself.

                        If it can't copy the file in, it saves GPSTeleport-pairing.plist next to the .exe. Get that onto your iPhone and tap "Import pairing file…" above.
                        """)
                        .font(.caption)
                    }
                }

                Section {
                    step(done: testPassed, title: "4. Test the connection",
                         detail: "Connects to your iPhone and installs Apple's Developer Disk Image if needed (one download, re-done after each restart). Doesn't change your location.")
                    switch testState {
                    case .idle:
                        EmptyView()
                    case .running(let message):
                        HStack { ProgressView(); Text(message).font(.caption) }
                    case .passed:
                        Label("Connected. You're ready to teleport.", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    case .failed(let message):
                        Text(message).font(.caption).foregroundStyle(.orange)
                    }
                    Button("Test connection", action: runTest)
                        .disabled(!hasPairing || isTesting)
                }
            }
            .navigationTitle("Setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: Self.pairingTypes) { result in
                switch result {
                case .success(let url): importPairing { try PairingStore.importFile(at: url) }
                case .failure(let error): pairingMessage = error.localizedDescription
                }
            }
            .onAppear {
                spoof.requestLocationPermission()
                hasPairing = PairingStore.exists
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                PairingStore.importFromDocumentsIfPresent()
                hasPairing = PairingStore.exists
                vpnLooksOn = LocalDevVPN.isConnected
            }
        }
    }

    private static let pairingTypes: [UTType] = [
        .propertyList,
        UTType(filenameExtension: "mobiledevicepairing") ?? .data,
        .data,
    ]

    private var isTesting: Bool {
        if case .running = testState { return true }
        return false
    }

    private var testPassed: Bool? {
        switch testState {
        case .passed: return true
        case .failed: return false
        default: return nil
        }
    }

    private func step(done: Bool?, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done == true ? "checkmark.circle.fill" : done == false ? "circle" : "info.circle")
                .foregroundStyle(done == true ? .green : .secondary)
                .font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func pasteFromClipboard() {
        guard let text = UIPasteboard.general.string, let data = text.data(using: .utf8) else {
            pairingMessage = "The clipboard doesn't contain text. Copy the whole pairing file contents first."
            return
        }
        importPairing { try PairingStore.importData(data) }
    }

    private func importPairing(_ work: () throws -> Void) {
        do {
            try work()
            hasPairing = true
            pairingMessage = "Pairing file imported."
        } catch {
            pairingMessage = error.localizedDescription
        }
    }

    private func runTest() {
        testState = .running("Starting…")
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try DeviceLink.shared.testConnection { message in
                    DispatchQueue.main.async { testState = .running(message) }
                }
                DispatchQueue.main.async { testState = .passed }
            } catch {
                DispatchQueue.main.async { testState = .failed(error.localizedDescription) }
            }
        }
    }
}
