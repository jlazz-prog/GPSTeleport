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
    @State private var showRefresh = false
    @State private var showSpots = false
    @State private var showSaveSpot = false
    @State private var newSpotName = ""

    @State private var mode: Mode = .teleport
    @State private var routeStart: CLLocationCoordinate2D?
    @State private var route: MKRoute?
    @State private var speed: DriveSpeed = .routePace
    @State private var isFindingRoute = false
    @State private var routeError: String?

    private enum Mode: String, CaseIterable, Identifiable {
        case teleport = "Teleport"
        case drive = "Drive"
        var id: Self { self }
    }

    private enum DriveSpeed: Hashable, CaseIterable, Identifiable {
        case routePace, mph25, mph45, mph65, mph80
        var id: Self { self }

        var label: String {
            switch self {
            case .routePace: return "Auto"
            case .mph25: return "25"
            case .mph45: return "45"
            case .mph65: return "65"
            case .mph80: return "80"
            }
        }

        /// "Auto" matches the average pace of Apple Maps' travel time for the route.
        func metersPerSecond(for route: MKRoute) -> Double {
            let metersPerSecondPerMph = 0.44704
            switch self {
            case .routePace:
                guard route.expectedTravelTime > 0, route.distance > 0 else { return 40 * metersPerSecondPerMph }
                return route.distance / route.expectedTravelTime
            case .mph25: return 25 * metersPerSecondPerMph
            case .mph45: return 45 * metersPerSecondPerMph
            case .mph65: return 65 * metersPerSecondPerMph
            case .mph80: return 80 * metersPerSecondPerMph
            }
        }
    }

    var body: some View {
        NavigationStack {
            MapReader { proxy in
                Map(position: $camera) {
                    UserAnnotation()
                    if let route {
                        MapPolyline(route.polyline)
                            .stroke(.purple, lineWidth: 5)
                    }
                    if let routeStart {
                        Marker("Start", systemImage: "flag", coordinate: routeStart)
                            .tint(.green)
                    }
                    if let pin {
                        Marker(mode == .drive ? "Destination" : "Teleport here", systemImage: "mappin", coordinate: pin)
                            .tint(.purple)
                    }
                    if let coordinate = spoof.spoofedCoordinate {
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
                        clearRoute()
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
                    Button { showRefresh = true } label: {
                        Image(systemName: "arrow.clockwise")
                            .foregroundStyle(AppExpiry.isExpiringSoon ? Color.orange : Color.accentColor)
                    }
                    .accessibilityLabel("Refresh")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSetup = true } label: { Image(systemName: "gearshape") }
                }
            }
            .sheet(isPresented: $showSetup) { SetupScreen() }
            .sheet(isPresented: $showRefresh) { RefreshScreen() }
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

            if !isDriving {
                Picker("Mode", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: mode) {
                    routeStart = nil
                    clearRoute()
                }
            }

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
                Text(mode == .drive ? "Tap the map or search to pick a destination." : "Tap the map or search to pick a spot.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if mode == .drive {
                driveOptions
            }

            HStack(spacing: 12) {
                primaryButton

                if isDriving {
                    Button {
                        if case .driving(let progress) = spoof.status {
                            spoof.setDrivePaused(!progress.isPaused)
                        }
                    } label: {
                        if case .driving(let progress) = spoof.status, progress.isPaused {
                            Label("Resume", systemImage: "play.fill").frame(maxWidth: .infinity)
                        } else {
                            Label("Pause", systemImage: "pause.fill").frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.bordered)
                }

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

    private var isDriving: Bool {
        if case .driving = spoof.status { return true }
        return false
    }

    @ViewBuilder
    private var primaryButton: some View {
        if mode == .teleport {
            Button {
                if let pin { spoof.teleport(to: pin) }
            } label: {
                Label("Spoof here", systemImage: "location.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.purple)
            .disabled(pin == nil || spoof.isBusy)
        } else if !isDriving {
            if let route {
                Button {
                    spoof.drive(along: route.polyline.coordinates,
                                metersPerSecond: speed.metersPerSecond(for: route))
                } label: {
                    Label("Start driving", systemImage: "car.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .disabled(spoof.isBusy)
            } else {
                Button(action: findRoute) {
                    Label(isFindingRoute ? "Finding route…" : "Find route", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .disabled(pin == nil || isFindingRoute || spoof.isBusy)
            }
        }
    }

    private var driveOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !isDriving {
                HStack {
                    Label(routeStartDescription, systemImage: "flag")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if routeStart != nil {
                        Button("Clear") {
                            routeStart = nil
                            clearRoute()
                        }
                        .font(.footnote)
                    } else if pin != nil {
                        Button("Start from pin") {
                            routeStart = pin
                            pin = nil
                            clearRoute()
                        }
                        .font(.footnote)
                    }
                }
            }

            if let route {
                if !isDriving {
                    Text("\(Self.miles(route.distance)) · \(Self.duration(route.distance / speed.metersPerSecond(for: route)))")
                        .font(.footnote.bold())
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Speed (mph)").font(.caption).foregroundStyle(.secondary)
                    Picker("Speed (mph)", selection: $speed) {
                        ForEach(DriveSpeed.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: speed) {
                        if isDriving {
                            spoof.setDriveSpeed(metersPerSecond: speed.metersPerSecond(for: route))
                        }
                    }
                }
            }

            if let routeError {
                Text(routeError).font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var routeStartDescription: String {
        if routeStart != nil { return "From the green flag" }
        if spoof.spoofedCoordinate != nil { return "From your spoofed location" }
        return "From your current location"
    }

    private static func miles(_ meters: Double) -> String {
        String(format: "%.1f mi", meters / 1609.344)
    }

    fileprivate static func duration(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) hr \(minutes % 60) min"
    }

    fileprivate static func remainingDescription(_ progress: SpoofController.DriveProgress) -> String {
        "\(miles(progress.remainingMeters)) left · \(duration(progress.remainingSeconds))"
    }

    // MARK: - Actions

    private func clearRoute() {
        route = nil
        routeError = nil
    }

    private func findRoute() {
        guard let pin else { return }
        routeError = nil
        isFindingRoute = true

        let request = MKDirections.Request()
        if let start = routeStart ?? spoof.spoofedCoordinate {
            request.source = MKMapItem(placemark: MKPlacemark(coordinate: start))
        } else {
            request.source = MKMapItem.forCurrentLocation()
        }
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: pin))
        request.transportType = .automobile

        MKDirections(request: request).calculate { response, error in
            isFindingRoute = false
            if let found = response?.routes.first {
                route = found
                camera = .rect(found.polyline.boundingMapRect.insetBy(
                    dx: -found.polyline.boundingMapRect.width * 0.2,
                    dy: -found.polyline.boundingMapRect.height * 0.2))
            } else {
                routeError = error?.localizedDescription ?? "Apple Maps couldn't find a driving route between those spots."
            }
        }
    }

    private func select(_ coordinate: CLLocationCoordinate2D) {
        pin = coordinate
        clearRoute()
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
        case .driving(let progress):
            VStack(alignment: .leading, spacing: 6) {
                if progress.isReconnecting {
                    label("Reconnecting: check LocalDevVPN", systemImage: "wifi.exclamationmark", color: .orange)
                } else if progress.isPaused {
                    label("Paused · \(MapScreen.remainingDescription(progress))", systemImage: "pause.circle.fill", color: .secondary)
                } else {
                    label("Driving · \(MapScreen.remainingDescription(progress))", systemImage: "car.fill", color: .green)
                }
                ProgressView(value: progress.fractionComplete).tint(.purple)
            }
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
