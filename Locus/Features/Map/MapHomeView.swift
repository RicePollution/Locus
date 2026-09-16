import MapKit
import SwiftUI

struct MapHomeView: View {
    @EnvironmentObject private var session: SpoofSession
    @EnvironmentObject private var pairing: PairingStore

    @StateObject private var search = PlaceSearchCompleter()
    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var searchText = ""
    @FocusState private var searchFocused: Bool
    @State private var routeStart: CLLocationCoordinate2D?
    @State private var routeEnd: CLLocationCoordinate2D?
    @State private var routeCoords: [CLLocationCoordinate2D] = []
    /// Every route MapKit offered for the last build, quickest first, plus which one the
    /// user picked. Apple Maps and Google Maps both show the alternates rather than
    /// silently committing to one, and the fastest is only the default, not the verdict.
    @State private var routeCandidates: [RoadRoute] = []
    @State private var selectedRouteID: RoadRoute.ID?
    /// Set after a route is built, imported, or taken from a drawing, so the planner
    /// can confirm a route actually exists. Nil means "no route loaded".
    @State private var routeStatus: String?
    @State private var isRouting = false
    @State private var showRouteSheet = false
    @State private var showGPXImporter = false
    /// Set when the planner is dismissed specifically to open the GPX picker, so the
    /// picker is presented from the sheet's real onDismiss rather than after a guessed delay.
    @State private var openImporterAfterPlannerDismiss = false
    @State private var drawnPath: [CLLocationCoordinate2D] = []
    @State private var drawMode = false
    @State private var pinSelected = false
    @State private var isDraggingPin = false
    /// Map taps are ignored until this instant. A pin drag that is cancelled rather than
    /// ended never delivers onDragEnded, so a sticky Bool could leave the map permanently
    /// untappable — panning still worked, which made it look like the map had taken over.
    /// A deadline expires on its own, so the worst case is one lost tap.
    @State private var suppressTapsUntil: Date = .distantPast
    /// Set when the pin comes from search / a named place so starring keeps the title.
    @State private var pinPlaceName: String?

    private var mapStyle: MapStyle {
        switch session.mapStyleIndex {
        case 1: return .hybrid(elevation: .realistic)
        case 2: return .imagery(elevation: .realistic)
        default: return .standard(elevation: .realistic)
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Keep Map inside the safe layout bounds so MapProxy.convert matches
            // finger position. Ignoring the safe area makes the tiles full-bleed but
            // shifts convert() upward by ~status-bar height.
            MapReader { proxy in
                Map(position: $position) {
                    UserAnnotation()

                    if let pin = session.pin {
                        Annotation("", coordinate: pin, anchor: .bottom) {
                            MapDropPin(
                                selected: pinSelected,
                                isDragging: isDraggingPin,
                                onSelect: {
                                    searchFocused = false
                                    suppressTapsUntil = Date().addingTimeInterval(0.15)
                                    withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                                        pinSelected.toggle()
                                    }
                                },
                                onRemove: {
                                    suppressTapsUntil = Date().addingTimeInterval(0.15)
                                    withAnimation {
                                        session.pin = nil
                                        pinSelected = false
                                    }
                                },
                                onDragBegan: {
                                    searchFocused = false
                                    suppressTapsUntil = Date().addingTimeInterval(0.3)
                                    pinSelected = false
                                    isDraggingPin = true
                                },
                                onDragMoved: { globalPoint in
                                    // Refresh the deadline as the drag runs, so it outlives the
                                    // gesture only briefly if the gesture dies without ending.
                                    suppressTapsUntil = Date().addingTimeInterval(0.3)
                                    if let coord = proxy.convert(globalPoint, from: .global) {
                                        session.pin = coord
                                    }
                                },
                                onDragEnded: {
                                    isDraggingPin = false
                                    suppressTapsUntil = Date().addingTimeInterval(0.15)
                                }
                            )
                        }
                    }
                    if let sim = session.simulated {
                        Annotation("Spoof", coordinate: sim) {
                            ZStack {
                                Circle().fill(LocusTheme.accent.opacity(0.25)).frame(width: 44, height: 44)
                                Circle().fill(LocusTheme.accent).frame(width: 14, height: 14)
                                    .overlay(Circle().stroke(.white, lineWidth: 2))
                            }
                        }
                    }
                    // Alternates sit behind the chosen route, greyed, the way Maps
                    // shows the ones you didn't pick — tapping one in the planner
                    // promotes it.
                    ForEach(routeCandidates.filter { $0.id != selectedRouteID }) { alternate in
                        MapPolyline(coordinates: alternate.coordinates)
                            .stroke(Color.secondary.opacity(0.45), lineWidth: 3)
                    }
                    if routeCoords.count > 1 {
                        MapPolyline(coordinates: routeCoords)
                            .stroke(LocusTheme.accent, lineWidth: 5)
                    }
                    if drawnPath.count > 1 {
                        MapPolyline(coordinates: drawnPath)
                            .stroke(LocusTheme.accentSecondary, style: StrokeStyle(lineWidth: 4, dash: [6, 4]))
                    }
                }
                .mapStyle(mapStyle)
                .mapControlVisibility(.hidden)
                // MapKit consumes taps before a plain .onTapGesture on the Map is
                // delivered when built against the iOS 26 SDK, so the handler never ran.
                // A simultaneous gesture does not demand exclusivity, so the map keeps its
                // own pan/zoom recognizers and we still see the tap.
                .simultaneousGesture(
                    SpatialTapGesture()
                        .onEnded { value in
                            handleMapTap(at: value.location, proxy: proxy)
                        }
                )
            }
            .background(Color.black.ignoresSafeArea())

            topChrome
        }
        .onAppear {
            session.startLocationUpdates()
        }
        .onChange(of: session.pin?.latitude) { _, newValue in
            if newValue == nil { pinSelected = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: .locusImportGPX)) { note in
            guard let url = note.object as? URL else { return }
            // Arrives from the share sheet with no Locus UI open, so the planner can be
            // shown immediately — nothing is mid-dismissal.
            importGPX(url, reopenPlanner: true)
        }
        .fileImporter(isPresented: $showGPXImporter, allowedContentTypes: [.xml, .data], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                // Do NOT re-present the planner here: this runs while the picker is still
                // dismissing, so the presentation is silently dropped while the binding
                // stays true, which would leave the planner permanently unreachable. The
                // route drawn on the map is the confirmation; reopening it shows the status.
                importGPX(url, reopenPlanner: false)
            }
        }
        .sheet(isPresented: $showRouteSheet, onDismiss: {
            guard openImporterAfterPlannerDismiss else { return }
            openImporterAfterPlannerDismiss = false
            showGPXImporter = true
        }) {
            RoutePlannerSheet(
                start: $routeStart,
                end: $routeEnd,
                isRouting: $isRouting,
                status: routeStatus,
                resolvedStart: resolvedRouteStart,
                candidates: routeCandidates,
                selectedRouteID: selectedRouteID,
                onBuild: buildRoadRoute,
                onSelectRoute: select(route:),
                onPlay: playRoute,
                onImportGPX: {
                    // The importer is attached to this view, which is covered while the
                    // planner is up, and presenting from a controller that is already
                    // presenting does nothing. Dismiss first and let onDismiss open the
                    // picker, so this waits on the real signal instead of a fixed delay.
                    openImporterAfterPlannerDismiss = true
                    showRouteSheet = false
                },
                onExportGPX: exportGPX,
                onUseDrawn: {
                    let sampled = RouteBuilder.sample(coordinates: drawnPath, every: 10)
                    guard !sampled.isEmpty else {
                        session.lastError = "Draw a path on the map first."
                        return
                    }
                    routeCoords = sampled
                    routeStatus = "Using drawn path — \(sampled.count) points. Tap Follow route."
                    clearRouteCandidates()
                    drawnPath.removeAll()
                    drawMode = false
                }
            )
            .presentationDetents([.medium, .large])
        }
    }

    private func handleMapTap(at point: CGPoint, proxy: MapProxy) {
        searchFocused = false
        // A cancelled pin drag can leave isDraggingPin set with no onDragEnded to clear
        // it. Once the suppression window has lapsed the drag is over whatever the flag
        // says, so heal it rather than staying wedged.
        if isDraggingPin, Date() >= suppressTapsUntil {
            isDraggingPin = false
        }
        guard Date() >= suppressTapsUntil, !isDraggingPin else { return }
        pinSelected = false
        placePin(at: point, proxy: proxy)
    }

    private func placePin(at point: CGPoint, proxy: MapProxy) {
        // convert returns nil for a point outside the map's own bounds, which a
        // simultaneous gesture can deliver. Nothing to report: ignore the tap.
        guard let coord = proxy.convert(point, from: .local) else { return }
        if drawMode {
            drawnPath.append(coord)
        } else {
            session.pin = coord
            pinPlaceName = nil
            pinSelected = false
        }
    }

    private var topChrome: some View {
        VStack(spacing: 10) {
            StatusBarView()

            searchBar

            if !searchText.isEmpty && !search.results.isEmpty {
                searchResults
            }

            HStack(alignment: .center, spacing: 10) {
                mapChromeButtons
                Spacer(minLength: 0)
                locateButton
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 2)
        .safeAreaPadding(.top, 8)
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search places", text: $searchText)
                .textInputAutocapitalization(.words)
                .focused($searchFocused)
                .submitLabel(.search)
                .onSubmit {
                    searchFocused = false
                }
                .onChange(of: searchText) { _, value in
                    search.query = value
                }
            if searchFocused || !searchText.isEmpty {
                Button {
                    searchText = ""
                    search.query = ""
                    searchFocused = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear and dismiss keyboard")
            }
            if searchFocused {
                Button("Done") {
                    searchFocused = false
                }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.plain)
                .foregroundStyle(LocusTheme.accent)
            }
        }
        .padding(12)
        .locusGlass(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var searchResults: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(search.results.prefix(5), id: \.self) { item in
                Button {
                    select(completion: item)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                        if !item.subtitle.isEmpty {
                            Text(item.subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider().opacity(0.3)
            }
        }
        .locusGlass(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var mapChromeButtons: some View {
        HStack(spacing: 4) {
            chromeIconButton("square.3.layers.3d") {
                session.mapStyleIndex = (session.mapStyleIndex + 1) % 3
            }
            chromeIconButton("point.topleft.down.to.point.bottomright.curvepath") {
                prepareRouteEndpoints()
                showRouteSheet = true
            }
            chromeIconButton(drawMode ? "pencil.tip.crop.circle.badge.minus" : "pencil.tip.crop.circle") {
                drawMode.toggle()
                if !drawMode { drawnPath.removeAll() }
            }
            .foregroundStyle(drawMode ? LocusTheme.accentSecondary : .primary)

            if session.pin != nil {
                chromeIconButton("star.circle") {
                    if let pin = session.pin {
                        let name = session.suggestedFavoriteName(for: pin, fallback: pinPlaceName)
                        session.addFavorite(name: name, coordinate: pin)
                    }
                }
            }
        }
        .padding(6)
        .locusGlass(.clear, in: Capsule())
        .contentShape(Capsule())
    }

    private var locateButton: some View {
        Button {
            searchFocused = false
            goToCurrentLocation()
        } label: {
            Image(systemName: "location.fill")
                .font(.body.weight(.semibold))
                .frame(width: 48, height: 48)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .locusGlass(.interactive, in: Circle())
        .foregroundStyle(.primary)
        .contentShape(Circle())
        .accessibilityLabel("Current location")
    }

    /// Centers on the spoofed fix while spoofing, otherwise the real GPS —
    /// never the leftover teleport pin (`.automatic` would frame that marker).
    private func goToCurrentLocation() {
        let meters: CLLocationDistance = 900
        withAnimation(.easeInOut(duration: 0.35)) {
            if session.isSpoofing, let sim = session.simulated {
                position = .region(MKCoordinateRegion(
                    center: sim,
                    latitudinalMeters: meters,
                    longitudinalMeters: meters
                ))
            } else if let real = session.realCoordinate {
                position = .region(MKCoordinateRegion(
                    center: real,
                    latitudinalMeters: meters,
                    longitudinalMeters: meters
                ))
            } else {
                position = .userLocation(
                    followsHeading: false,
                    fallback: .region(MKCoordinateRegion(
                        center: CLLocationCoordinate2D(latitude: 37.3349, longitude: -122.0090),
                        latitudinalMeters: 2000,
                        longitudinalMeters: 2000
                    ))
                )
            }
        }
    }

    private func chromeIconButton(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }

    private func select(completion: MKLocalSearchCompletion) {
        Task {
            let request = MKLocalSearch.Request(completion: completion)
            if let response = try? await MKLocalSearch(request: request).start(),
               let item = response.mapItems.first {
                let coord = item.placemark.coordinate
                let title = item.name ?? completion.title
                await MainActor.run {
                    session.pin = coord
                    pinPlaceName = title
                    position = .region(MKCoordinateRegion(center: coord, latitudinalMeters: 1200, longitudinalMeters: 1200))
                    searchText = ""
                    search.query = ""
                    searchFocused = false
                    session.addFavorite(name: title, coordinate: coord)
                    session.pushNamedRecent(name: title, coordinate: coord)
                }
            }
        }
    }

    /// Where a route starts when the user has not named a start: wherever they are.
    ///
    /// Deliberately computed on every read rather than stored, so it follows a teleport.
    /// The pin is the last resort and not the first: it is also where "Set end to pin"
    /// puts the end, so preferring it asked MapKit to route a point to itself, and MapKit
    /// answers that with a flat "directions not available" that reads as "your
    /// destination is unreachable".
    private var resolvedRouteStart: CLLocationCoordinate2D? {
        routeStart ?? session.simulated ?? session.realCoordinate ?? session.pin
    }

    /// Adopt the dropped pin as the destination when the user has not set one, so the
    /// common path — drop a pin, open the planner, build — needs no setup at all.
    private func prepareRouteEndpoints() {
        if routeEnd == nil, let pin = session.pin, !isSameSpot(pin, resolvedRouteStart) {
            routeEnd = pin
        }
    }

    private func isSameSpot(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D?) -> Bool {
        guard let b else { return false }
        return CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
            < RouteBuilder.minimumRouteDistance
    }

    private func buildRoadRoute() {
        guard let start = resolvedRouteStart, let end = routeEnd ?? session.pin else {
            session.lastError = "Set a route start and end."
            return
        }
        isRouting = true
        let mode = session.travelMode
        Task {
            do {
                let routes = try await RouteBuilder.roadRoutes(from: start, to: end, mode: mode)
                await MainActor.run {
                    isRouting = false
                    routeEnd = end
                    routeCandidates = routes
                    if let best = routes.first {
                        select(route: best)
                    }
                }
            } catch {
                await MainActor.run {
                    isRouting = false
                    routeStatus = nil
                    clearRouteCandidates()
                    session.lastError = error.localizedDescription
                }
            }
        }
    }

    private func select(route: RoadRoute) {
        selectedRouteID = route.id
        routeCoords = route.coordinates
        frame(coordinates: route.coordinates)
        let summary = "\(RoutePlannerSheet.distanceText(route.distance)) · "
            + "\(RoutePlannerSheet.durationText(route.expectedTravelTime))"
        routeStatus = route.fellBackToRoads
            ? "Route ready — \(summary), following roads (no footpath route available). Tap Follow route."
            : "Route ready — \(summary). Tap Follow route."
    }

    /// Put the whole route on screen once it is built. A route that starts off-camera
    /// looks like nothing happened, which is most of them: the end pin is usually the
    /// only part of it the user has actually looked at.
    private func frame(coordinates: [CLLocationCoordinate2D]) {
        guard let first = coordinates.first else { return }
        var rect = MKMapRect(origin: MKMapPoint(first), size: MKMapSize(width: 0, height: 0))
        for coordinate in coordinates.dropFirst() {
            let point = MKMapPoint(coordinate)
            rect = rect.union(MKMapRect(origin: point, size: MKMapSize(width: 0, height: 0)))
        }
        // A straight north-south or east-west route has zero extent on one axis, and
        // insetting a zero side by a fraction of itself leaves it zero, so the camera
        // would try to frame a line with no width. Give it a floor in map points first.
        let minimumSide = max(rect.size.width, rect.size.height, 400) * 0.15
        position = .rect(rect.insetBy(dx: -minimumSide, dy: -minimumSide))
    }

    /// A route from GPX, a drawing, or a failed build has no MapKit alternates behind it;
    /// leaving the old ones listed would offer a choice that no longer draws anything.
    private func clearRouteCandidates() {
        routeCandidates = []
        selectedRouteID = nil
    }

    private func playRoute() {
        let path = routeCoords.isEmpty ? drawnPath : routeCoords
        guard path.count >= 2 else {
            session.lastError = "Build or draw a route first."
            return
        }
        showRouteSheet = false
        session.followRoute(path, pairing: pairing)
    }

    private func importGPX(_ url: URL, reopenPlanner: Bool) {
        do {
            let coords = try GPXCodec.parse(url)
            routeCoords = RouteBuilder.sample(coordinates: coords, every: 10)
            routeStatus = "Imported \(coords.count) GPX points (\(routeCoords.count) after sampling). Tap Follow route."
            clearRouteCandidates()
            if let first = coords.first {
                session.pin = first
                position = .region(MKCoordinateRegion(center: first, latitudinalMeters: 2000, longitudinalMeters: 2000))
            }
            if reopenPlanner {
                showRouteSheet = true
            }
        } catch {
            session.lastError = error.localizedDescription
        }
    }

    private func exportGPX() {
        let path = routeCoords.isEmpty ? drawnPath : routeCoords
        guard !path.isEmpty else {
            session.lastError = "Nothing to export."
            return
        }
        let gpx = GPXCodec.export(path)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Locus-Route.gpx")
        do {
            try gpx.data(using: .utf8)?.write(to: url)
            let av = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let root = scene.keyWindow?.rootViewController {
                // The planner sheet is usually still up; presenting from the root while
                // it is presenting does nothing, so walk to the topmost controller.
                var top = root
                while let presented = top.presentedViewController { top = presented }
                // iPad is a supported device family, and a popover without a source
                // anchor traps on presentation.
                if let popover = av.popoverPresentationController {
                    popover.sourceView = top.view
                    popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.maxY, width: 0, height: 0)
                    popover.permittedArrowDirections = []
                }
                top.present(av, animated: true)
            }
        } catch {
            session.lastError = error.localizedDescription
        }
    }
}

private extension UIWindowScene {
    var keyWindow: UIWindow? { windows.first { $0.isKeyWindow } }
}

@MainActor
final class PlaceSearchCompleter: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var results: [MKLocalSearchCompletion] = []
    private let completer = MKLocalSearchCompleter()

    var query: String = "" {
        didSet {
            completer.queryFragment = query
        }
    }

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let items = completer.results
        Task { @MainActor in self.results = items }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in self.results = [] }
    }
}
