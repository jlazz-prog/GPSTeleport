import SwiftUI
import MapKit

struct MapScreen: View {
    @EnvironmentObject private var spoof: SpoofController
    @EnvironmentObject private var spots: SavedSpots

    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var pin: CLLocationCoordinate2D?
    @State private var searchText = ""
    @State private var searchResults: [MKMapItem] = []
    @State private var showSetup = false
    @State private var showSpots = false
    @State private var showSaveSpot = false
    @State private var newSpotName = ""

    var body: some View {
        NavigationStack {
            MapReader { proxy in
                Map(position: $camera) {
                    UserAnnotation()
                    if let pin {
                        Marker("Teleport here", systemImage: "mappin", coordinate: pin)
                            .tint(.purple)
                    }
                    if case .active(let coordinate) = spoof.status {
                        Annotation("You (spoofed)", coordinate: coordinate) {
                            Image(systemName: "location.circle.fill")
                                .font(.title)
                                .foregroundStyle(.white, .purple)
                        }
                    }
                }
                .mapControls {
                    MapUserLocationButton()
                    MapCompass()
                }
                .onTapGesture { point in
                    if let coordinate = proxy.convert(point, from: .local) {
                        pin = coordinate
                        searchResults = []
                    }
                }
            }
            .ignoresSafeArea(edges: .bottom)
            .safeAreaInset(edge: .top) { searchResultsList }
            .safeAreaInset(edge: .bottom) { controlPanel }
            .searchable(text: $searchText, prompt: "Search a place or address")
            .onSubmit(of: .search, runSearch)
            .navigationTitle("GPS Teleport")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSpots = true } label: { Image(systemName: "star") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSetup = true } label: { Image(systemName: "gearshape") }
                }
            }
            .sheet(isPresented: $showSetup) { SetupScreen() }
            .sheet(isPresented: $showSpots) {
                SavedSpotsScreen { spot in
                    select(spot.coordinate)
                    showSpots = false
                }
            }
            .alert("Save this spot", isPresented: $showSaveSpot) {
                TextField("Name (e.g. Home)", text: $newSpotName)
                Button("Save") {
                    if let pin { spots.add(name: newSpotName, coordinate: pin) }
                    newSpotName = ""
                }
                Button("Cancel", role: .cancel) { newSpotName = "" }
            }
            .onAppear {
                if !PairingStore.exists { showSetup = true }
            }
        }
    }

    // MARK: - Pieces

    @ViewBuilder
    private var searchResultsList: some View {
        if !searchResults.isEmpty {
            List(searchResults, id: \.self) { item in
                Button {
                    if let coordinate = item.placemark.location?.coordinate { select(coordinate) }
                    searchResults = []
                } label: {
                    VStack(alignment: .leading) {
                        Text(item.name ?? "Unnamed place").foregroundStyle(.primary)
                        Text(item.placemark.title ?? "").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.plain)
            .frame(maxHeight: 260)
        }
    }

    private var controlPanel: some View {
        VStack(spacing: 12) {
            StatusBanner(status: spoof.status) { spoof.dismissError() }

            if let pin {
                HStack {
                    Text(String(format: "%.5f, %.5f", pin.latitude, pin.longitude))
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button { showSaveSpot = true } label: { Label("Save", systemImage: "star") }
                        .font(.footnote)
                }
            } else if !spoof.isActive {
                Text("Tap the map or search to pick a spot.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Button {
                    if let pin { spoof.teleport(to: pin) }
                } label: {
                    Label("Spoof here", systemImage: "location.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .disabled(pin == nil || spoof.isBusy)

                if spoof.isActive {
                    Button(role: .destructive) {
                        spoof.stop()
                    } label: {
                        Label("Stop", systemImage: "xmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(spoof.isBusy)
                }
            }
            .controlSize(.large)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    // MARK: - Actions

    private func select(_ coordinate: CLLocationCoordinate2D) {
        pin = coordinate
        camera = .region(MKCoordinateRegion(center: coordinate,
                                            span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)))
    }

    private func runSearch() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        MKLocalSearch(request: request).start { response, _ in
            let items = response?.mapItems ?? []
            if items.count == 1, let coordinate = items[0].placemark.location?.coordinate {
                select(coordinate)
                searchResults = []
            } else {
                searchResults = Array(items.prefix(8))
            }
        }
    }
}

private struct StatusBanner: View {
    let status: SpoofController.Status
    let onDismiss: () -> Void

    var body: some View {
        switch status {
        case .off:
            label("Not spoofing: apps see your real location", systemImage: "location.slash", color: .secondary)
        case .working(let message):
            HStack(spacing: 8) {
                ProgressView()
                Text(message).font(.subheadline)
                Spacer()
            }
        case .active(let coordinate):
            label(String(format: "Spoofing at %.4f, %.4f", coordinate.latitude, coordinate.longitude),
                  systemImage: "checkmark.circle.fill", color: .green)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                label("Didn't work", systemImage: "exclamationmark.triangle.fill", color: .orange)
                Text(message).font(.caption).foregroundStyle(.secondary)
                Button("OK", action: onDismiss).font(.caption.bold())
            }
        }
    }

    private func label(_ text: String, systemImage: String, color: Color) -> some View {
        HStack {
            Image(systemName: systemImage).foregroundStyle(color)
            Text(text).font(.subheadline)
            Spacer()
        }
    }
}
