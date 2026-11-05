import SwiftUI
import MapKit

struct MapScreen: View {
    @EnvironmentObject private var spoof: SpoofController
    @EnvironmentObject private var spots: SavedSpots
    @EnvironmentObject private var refresher: AppRefresher

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
    @State private var route: PlannedRoute?
    @State private var trafficNote: String?
    @State private var speed: DriveSpeed = .routePace
    @AppStorage("customDriveMph") private var customMph = 50.0
    @State private var isFindingRoute = false
    @State private var routeError: String?

    private enum Mode: String, CaseIterable, Identifiable {
        case teleport = "Teleport"
        case drive = "Drive"
        var id: Self { self }
    }

    private enum DriveSpeed: Hashable, CaseIterable, Identifiable {
        case routePace, mph25, mph35, mph45, mph65, mph80, custom
        var id: Self { self }

        var label: String {
            switch self {
            case .routePace: return "Auto"
            case .mph25: return "25"
            case .mph35: return "35"
            case .mph45: return "45"
            case .mph65: return "65"
            case .mph80: return "80"
            case .custom: return "Custom"
            }
        }

        /// "Auto" is the route's average pace. With live traffic that's only used on
        /// stretches where Mapbox has no speed.
        func metersPerSecond(for route: PlannedRoute, customMph: Double) -> Double {
            let metersPerSecondPerMph = 0.44704
            switch self {
            case .custom: return customMph * metersPerSecondPerMph
            case .routePace:
                guard route.expectedTravelTime > 0, route.distance > 0 else { return 40 * metersPerSecondPerMph }
                return route.distance / route.expectedTravelTime
            case .mph25: return 25 * metersPerSecondPerMph
            case .mph35: return 35 * metersPerSecondPerMph
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
                        MapPolyline(spoof.updatedRoute ?? route.polyline)
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
            automaticRefreshBanner

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

    /// True when the button would only repeat what's happening. With no pin, or a new pin
    /// somewhere else, it still offers to move: a new pin means "Spoof here" is the next step.
    private var isSpoofingAtPin: Bool {
        guard case .active(let coordinate) = spoof.status else { return false }
        guard let pin else { return true }
        return pin.latitude == coordinate.latitude && pin.longitude == coordinate.longitude
    }

    @ViewBuilder
    private var automaticRefreshBanner: some View {
        if refresher.isAutomatic {
            switch refresher.state {
            case .working(let message):
                HStack(spacing: 8) {
                    ProgressView()
                    VStack(alignment: .leading) {
                        Text("Refreshing GPS Teleport").font(.subheadline.bold())
                        Text("\(message) The app closes when it's done.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            case .finished:
                Label("Refreshed. Close GPS Teleport and open it again.", systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.green)
            case .failed:
                VStack(alignment: .leading, spacing: 6) {
                    Label("Automatic refresh didn't work", systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                    Button("Refresh by hand") { showRefresh = true }
                        .font(.caption.bold())
                }
            case .idle, .needsCode:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        if mode == .teleport {
            Button {
                if let pin { spoof.teleport(to: pin) }
            } label: {
                Label(isSpoofingAtPin ? "Spoofing" : "Spoof here",
                      systemImage: isSpoofingAtPin ? "checkmark.circle.fill" : "location.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.purple)
            .disabled(pin == nil || isSpoofingAtPin || spoof.isBusy || refresher.isRunning)
        } else if !isDriving {
            if let route {
                Button {
                    spoof.drive(along: route.polyline.coordinates,
                                trafficSpeeds: route.trafficSpeeds,
                                metersPerSecond: speed.metersPerSecond(for: route, customMph: customMph),
                                followTraffic: speed == .routePace)
                } label: {
                    Label("Start driving", systemImage: "car.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .disabled(spoof.isBusy || refresher.isRunning)
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
                    Text("\(Self.miles(route.distance)) · \(Self.duration(route.distance / speed.metersPerSecond(for: route, customMph: customMph)))")
                        .font(.footnote.bold())
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Speed (mph)").font(.caption).foregroundStyle(.secondary)
                    Picker("Speed (mph)", selection: $speed) {
                        ForEach(DriveSpeed.allCases) { option in
                            // Seven segments leave too little room for the word "Custom".
                            if option == .custom {
                                Image(systemName: "slider.horizontal.3")
                                    .accessibilityLabel(option.label)
                                    .tag(option)
                            } else {
                                Text(option.label).tag(option)
                            }
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: speed) { updateDriveSpeed(for: route) }

                    if speed == .custom {
                        HStack {
                            Slider(value: $customMph, in: 1...100, step: 1)
                                .accessibilityLabel("Custom speed")
                                .accessibilityValue("\(Int(customMph)) miles per hour")
                                .onChange(of: customMph) { updateDriveSpeed(for: route) }
                            Text("\(Int(customMph)) mph")
                                .font(.footnote.monospacedDigit())
                                .frame(width: 58, alignment: .trailing)
                        }
                    }

                    if route.trafficSpeeds != nil {
                        if speed == .routePace {
                            Label("Auto follows live traffic", systemImage: "car.2.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 8) {
                            Link("© Mapbox", destination: URL(string: "https://www.mapbox.com/about/maps")!)
                            Link("© OpenStreetMap", destination: URL(string: "https://www.openstreetmap.org/about")!)
                        }
                        .font(.caption2)
                    }
                }
            }

            if let trafficNote, route != nil {
                Text("Using Apple's average speed. \(trafficNote)").font(.caption).foregroundStyle(.orange)
            }

            if let routeError {
                Text(routeError).font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func updateDriveSpeed(for route: PlannedRoute) {
        if isDriving {
            spoof.setDriveSpeed(metersPerSecond: speed.metersPerSecond(for: route, customMph: customMph),
                                followTraffic: speed == .routePace)
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
        trafficNote = nil
    }

    /// Uses Mapbox's route with live traffic when there's a token. Otherwise, or if that
    /// fails, it uses Apple Maps' route at one average speed.
    private func findRoute() {
        guard let pin else { return }
        clearRoute()
        isFindingRoute = true
        let start = routeStart ?? spoof.spoofedCoordinate

        guard LiveTraffic.hasToken else {
            findAppleRoute(from: start, to: pin)
            return
        }
        guard let origin = start ?? CLLocationManager().location?.coordinate else {
            trafficNote = "Your current location isn't available yet."
            findAppleRoute(from: start, to: pin)
            return
        }

        Task { @MainActor in
            do {
                show(PlannedRoute(try await LiveTraffic.route(from: origin, to: pin)))
            } catch {
                trafficNote = error.localizedDescription
                findAppleRoute(from: start, to: pin)
            }
        }
    }

    private func findAppleRoute(from start: CLLocationCoordinate2D?, to destination: CLLocationCoordinate2D) {
        let request = MKDirections.Request()
        if let start {
            request.source = MKMapItem(placemark: MKPlacemark(coordinate: start))
        } else {
            request.source = MKMapItem.forCurrentLocation()
        }
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination))
        request.transportType = .automobile

        MKDirections(request: request).calculate { response, error in
            if let found = response?.routes.first {
                show(PlannedRoute(found))
            } else {
                isFindingRoute = false
                routeError = error?.localizedDescription ?? "Apple Maps couldn't find a driving route between those spots."
            }
        }
    }

    private func show(_ found: PlannedRoute) {
        isFindingRoute = false
        route = found
        let bounds = found.polyline.boundingMapRect
        camera = .rect(bounds.insetBy(dx: -bounds.width * 0.2, dy: -bounds.height * 0.2))
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
                    label("\(Int((progress.metersPerSecond / 0.44704).rounded())) mph · \(MapScreen.remainingDescription(progress))",
                          systemImage: progress.isFollowingTraffic ? "car.2.fill" : "car.fill", color: .green)
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
