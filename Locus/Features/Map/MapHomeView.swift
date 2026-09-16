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
    /// Route-planner errors live here, not in `session.lastError`: that alert is bound on
    /// RootView, behind this sheet, and a controller that is already presenting cannot
    /// present again.
    @State private var routeError: String?
    /// Held so a build can be abandoned. Without this a slow build lands on top of a GPX
    /// the user imported while it was in flight and silently replaces it.
    @State private var routeBuildTask: Task<Void, Never>?
    /// The endpoints the loaded route was built from, so a changed pin can be reported
    /// instead of leaving confident mileage sitting under endpoints it never described.
    @State private var routeBuiltFor: RouteEndpoints?
    /// The pin last adopted as a destination, so a *newly dropped* pin becomes the
    /// destination while an endpoint the user set deliberately survives.
    @State private var lastAdoptedPin: CLLocationCoordinate2D?
    /// Set after a route is built, imported, or taken from a drawing, so the planner
    /// can confirm a route actually exists. Nil means "no route loaded".
    @State private var routeStatus: String?
    /// The posted-limit lookup for the selected route, held so reselecting or rebuilding can
    /// abandon it. Nil means nothing is in flight.
    @State private var speedLookupTask: Task<Void, Never>?
    /// Profile for the route currently drawn, once its lookup has landed.
    @State private var activeProfile: SpeedProfile?
    /// What the planner says about posted limits for the selected route.
    @State private var speedLimitStatus: String?
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
                errorText: routeError,
                isStale: routeIsStale,
                speedLimitStatus: speedLimitStatus,
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
                    guard sampled.count > 1 else {
                        routeError = "Draw a path on the map first — tap the pencil, then tap along the route."
                        return
                    }
                    cancelRouteBuild()
                    routeError = nil
                    // A drawing was never built from endpoints, so the staleness warning
                    // has nothing to compare against and would fire on the next new pin.
                    routeBuiltFor = nil
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
                routeError = nil
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

    /// Adopt the dropped pin as the destination, so the common path — drop a pin, open
    /// the planner, build — needs no setup at all.
    ///
    /// Keyed on the pin having *moved*, not on the end being unset. Using nil-ness as the
    /// proxy for "the user hasn't chosen" made this a one-shot: after the first build the
    /// end was permanently non-nil, so dropping a new pin and tapping Build silently
    /// rebuilt the route to the old destination, with nothing but a raw lat/lon in the
    /// sheet to say so. Comparing against the last pin we adopted keeps a deliberately
    /// swapped endpoint intact while still following a new pin.
    private func prepareRouteEndpoints() {
        guard let pin = session.pin else { return }
        guard !isSameSpot(pin, lastAdoptedPin) else { return }
        guard !isSameSpot(pin, resolvedRouteStart) else { return }
        routeEnd = pin
        lastAdoptedPin = pin
    }

    /// True when the loaded route no longer describes the endpoints shown beside it.
    /// Changing an endpoint without rebuilding used to leave the alternates, the drawn
    /// polyline and the ETA all describing the previous pair, which is worse than having
    /// no route at all: the numbers are specific, confident, and about somewhere else.
    /// Suppressed *while following*, not always. The resolved start floats on
    /// `session.simulated`, which playback moves continuously, so keying staleness to it
    /// unconditionally would light the warning up for a route doing exactly what was
    /// asked. But suppressing it outright hid the case that actually matters: teleport
    /// somewhere after building, and the planner would show Start and End as the same
    /// coordinate under a status line still quoting the old route's mileage — and Follow
    /// route would teleport back to the original start and drive from there.
    private var routeIsStale: Bool {
        guard let built = routeBuiltFor else { return false }
        if let end = routeEnd ?? session.pin,
           end.latitude != built.endLatitude || end.longitude != built.endLongitude {
            return true
        }
        guard !session.isFollowingRoute else { return false }
        if let start = resolvedRouteStart,
           start.latitude != built.startLatitude || start.longitude != built.startLongitude {
            return true
        }
        return false
    }

    private func cancelRouteBuild() {
        routeBuildTask?.cancel()
        routeBuildTask = nil
        isRouting = false
    }

    private func isSameSpot(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D?) -> Bool {
        guard let b else { return false }
        return CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
            < RouteBuilder.minimumRouteDistance
    }

    private func buildRoadRoute() {
        // Name which endpoint is missing. "Set a route start and end" fired both when no
        // destination was set and when no start was available at all — location denied,
        // nothing simulated, no pin — telling the user to set endpoints with a pin they
        // do not have.
        guard let start = resolvedRouteStart else {
            routeError = "No start position yet. Drop a pin and tap \"Set start to pin\", or "
                + "allow location access so Locus knows where you are."
            return
        }
        guard let end = routeEnd ?? session.pin else {
            routeError = "No destination yet. Tap the map to drop a pin, then \"Set end to pin\"."
            return
        }
        cancelRouteBuild()
        routeError = nil
        isRouting = true
        let mode = session.travelMode
        routeBuildTask = Task {
            do {
                let routes = try await RouteBuilder.roadRoutes(from: start, to: end, mode: mode)
                if Task.isCancelled { return }
                isRouting = false
                // `guard` rather than `if let`: an empty result would otherwise leave the
                // previous route drawn under a fresh, empty candidate list.
                guard let best = routes.first else {
                    failBuild(with: RouteError.noRoute(mode).localizedDescription)
                    return
                }
                routeCandidates = routes
                routeBuiltFor = RouteEndpoints(start: start, end: end)
                guard load(route: best) else {
                    failBuild(with: "That route came back without a path to follow. Try rebuilding.")
                    return
                }
                routeBuildTask = nil
            } catch {
                if Task.isCancelled { return }
                isRouting = false
                failBuild(with: error.localizedDescription)
            }
        }
    }

    /// Clear the *whole* route, not part of it. Clearing the status and the alternates
    /// while leaving `routeCoords` drawn left a bold accent polyline on the map that
    /// Follow route would happily play: build a route to A, then fail a build to B, and
    /// the device drives to A while the user believes nothing was loaded.
    private func failBuild(with message: String) {
        routeError = message
        routeStatus = nil
        routeCoords = []
        routeBuiltFor = nil
        clearRouteCandidates()
    }

    /// Selecting an alternate from the list must not be able to destroy a good loaded
    /// route. Tapping a sibling that came back without geometry used to unwind the whole
    /// build — the drawn route, the status and all three candidates — so you lost a
    /// working route by looking at a broken one.
    private func select(route: RoadRoute) {
        guard load(route: route) else {
            routeError = "That alternate came back without a path to follow — keeping the current route."
            return
        }
    }

    /// Install a candidate as the active route. Returns false, touching nothing, when the
    /// candidate has no usable geometry, so each caller decides what that means.
    private func load(route: RoadRoute) -> Bool {
        // MapKit's distance and ETA come from MKRoute, not from the geometry, so they
        // stay plausible when the geometry is empty — and an empty `routeCoords` makes
        // playRoute fall through to the drawn path, following something the user never
        // chose under a status line claiming a specific mileage.
        guard route.coordinates.count > 1 else { return false }
        selectedRouteID = route.id
        routeCoords = route.coordinates
        routeError = nil
        frame(coordinates: route.coordinates)

        var parts = [RouteFormat.summary(for: route)]
        if let fallback = route.fallback {
            parts.append(fallback.explanation)
        }
        if route.droppedVertices {
            parts.append("long route, shape simplified so corners are approximate")
        } else if let spacing = route.simplifiedSpacing {
            // Wider spacing alone drops no MKRoute vertex — every leg's last interpolated
            // point lands exactly on the source point — so the shape is intact and only
            // the playback granularity is coarser. Claiming approximate corners here
            // would be an over-warning.
            parts.append("long route, \(Int(spacing.rounded())) m between playback points")
        }
        // Attributed rather than stated flatly: the ETA is Apple's estimate for a real
        // car, while playback runs at the travel mode's own speed, and the two numbers
        // are not the same. Claiming the first as ours would be a promise the follower
        // does not keep.
        routeStatus = "Route ready — \(parts.joined(separator: ", ")) (Maps estimate). Tap Follow route."
        startSpeedLimitLookup(for: route)
        return true
    }

    /// Longest a Follow will wait for an in-flight limit lookup before starting anyway.
    private static let followProfileDeadline: TimeInterval = 3

    /// Ask Overpass for this route's posted limits. Deliberately hung off the point where a
    /// route becomes the active one rather than off the build: the route is drawn, framed and
    /// followable before a single byte leaves the device, and nothing here can block that.
    private func startSpeedLimitLookup(for route: RoadRoute) {
        speedLookupTask?.cancel()
        speedLookupTask = nil
        activeProfile = route.speedProfile
        let mode = session.travelMode
        guard mode == .drive else {
            speedLimitStatus = nil
            return
        }
        guard SpeedLimitSettings.isEnabled else {
            speedLimitStatus = "Speed limits: off"
            return
        }
        if let profile = route.speedProfile {
            speedLimitStatus = Self.speedLimitSummary(for: profile)
            return
        }
        speedLimitStatus = "Speed limits: looking up…"
        let routeID = route.id
        speedLookupTask = Task {
            let outcome = await SpeedLimitService.shared.profile(for: route, mode: mode)
            if Task.isCancelled { return }
            install(outcome, forRouteID: routeID)
        }
    }

    /// A profile describes one specific polyline, so it may only be attached to the candidate
    /// it was looked up for — a rebuild while it was in flight has already retired that id,
    /// and a reselect has moved the selection off it.
    private func install(_ outcome: SpeedLimitService.Outcome, forRouteID id: RoadRoute.ID) {
        guard let index = routeCandidates.firstIndex(where: { $0.id == id }) else { return }
        if case .profile(let profile) = outcome {
            routeCandidates[index].speedProfile = profile
        }
        guard id == selectedRouteID else { return }
        speedLookupTask = nil
        switch outcome {
        case .profile(let profile):
            activeProfile = profile
            speedLimitStatus = Self.speedLimitSummary(for: profile)
        case .disabled:
            speedLimitStatus = "Speed limits: off"
        case .notApplicable(let reason):
            speedLimitStatus = "Speed limits: \(reason)"
        case .unavailable(let reason):
            // Name what it falls back to. "Unavailable" on its own reads as "the route will
            // not play", which is the one thing that is never true here.
            let fallback = routeCandidates[index].averageSpeed != nil
                ? "using route average"
                : "using the travel mode's speed"
            speedLimitStatus = "Speed limits: unavailable — \(reason), \(fallback)"
        }
    }

    private static func speedLimitSummary(for profile: SpeedProfile) -> String {
        let count = profile.zones.count
        var parts = [
            "\(count) zone\(count == 1 ? "" : "s")",
            "\(Int((profile.postedCoverage * 100).rounded()))% posted"
        ]
        // Shown next to MapKit's ETA rather than instead of it: the two will differ, and a
        // user who notices deserves the number rather than a surprise.
        if let implied = RouteFormat.duration(profile.impliedDuration) {
            parts.append("~\(implied)")
        }
        return "Speed limits: " + parts.joined(separator: " · ")
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
        // A route that crosses the antimeridian unions into a rect spanning nearly the
        // whole world, and framing that shows the planet instead of the route. Leaving
        // the camera where it is beats zooming out to nothing. Real on Taveuni, Fiji,
        // where the 180th meridian crosses roads people drive.
        guard rect.size.width < MKMapSize.world.width / 2 else { return }
        let minimumSide = max(rect.size.width, rect.size.height, 400) * 0.15
        position = .rect(rect.insetBy(dx: -minimumSide, dy: -minimumSide))
    }

    /// A route from GPX, a drawing, or a failed build has no MapKit alternates behind it;
    /// leaving the old ones listed would offer a choice that no longer draws anything.
    private func clearRouteCandidates() {
        routeCandidates = []
        selectedRouteID = nil
        speedLookupTask?.cancel()
        speedLookupTask = nil
        activeProfile = nil
        speedLimitStatus = nil
    }

    private func playRoute() {
        let path = routeCoords.isEmpty ? drawnPath : routeCoords
        guard path.count >= 2 else {
            routeError = "Build or draw a route first."
            return
        }
        // A build still in flight would land after this and replace the route under the
        // one now being followed, yanking the camera to a path the user is not on.
        cancelRouteBuild()
        showRouteSheet = false
        // A posted car limit is not a pedestrian's speed, so a mode switched away from
        // driving after the build must not inherit the profile the build looked up.
        guard session.travelMode == .drive else {
            session.followRoute(path, pairing: pairing)
            return
        }
        let stopMark = session.stopGeneration
        Task {
            await awaitProfileBriefly()
            // Stop tapped during the wait had no routeTask to cancel, so without this the
            // follow it was cancelling would start behind it.
            guard session.stopGeneration == stopMark else { return }
            session.followRoute(path, profile: activeProfile, pairing: pairing)
        }
    }

    /// Give an in-flight lookup a moment to land before starting.
    ///
    /// Build-then-Follow inside a second or two is the common gesture, and without this the
    /// first follow of a route silently runs at the old fixed speed while the profile lands
    /// behind it — which reads as the feature not working. Polling rather than racing the
    /// task: `Task<Void, Never>.value` is not cancellation-aware, so a task group would wait
    /// for the lookup on the way out and the deadline would do nothing.
    ///
    /// The deadline expiring does NOT cancel the lookup: it keeps running and still installs,
    /// so the next Follow of this route is correct from cache.
    private func awaitProfileBriefly() async {
        let deadline = Date().addingTimeInterval(Self.followProfileDeadline)
        while activeProfile == nil, speedLookupTask != nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func importGPX(_ url: URL, reopenPlanner: Bool) {
        do {
            let coords = try GPXCodec.parse(url)
            // A build started before the picker opened would otherwise land on top of
            // this and silently replace it.
            cancelRouteBuild()
            routeError = nil
            routeBuiltFor = nil
            routeCoords = RouteBuilder.sample(coordinates: coords, every: 10)
            routeStatus = "Imported \(coords.count) GPX points (\(routeCoords.count) after sampling). Tap Follow route."
            clearRouteCandidates()
            if let first = coords.first {
                session.pin = first
                // Recorded as adopted, or the next planner open takes the imported
                // track's own start as the destination.
                lastAdoptedPin = first
                position = .region(MKCoordinateRegion(center: first, latitudinalMeters: 2000, longitudinalMeters: 2000))
            }
            if reopenPlanner {
                showRouteSheet = true
            }
        } catch {
            report(error.localizedDescription)
        }
    }

    /// Route problems go to the planner when it is open and to the app-wide alert when it
    /// is not. GPX import is reachable both ways — through the file picker, which closes
    /// the planner first, and through `onOpenURL` from the share sheet, which can land
    /// while the planner is still up — and the alert is bound behind the planner.
    private func report(_ message: String) {
        if showRouteSheet {
            routeError = message
        } else {
            session.lastError = message
        }
    }

    private func exportGPX() {
        let path = routeCoords.isEmpty ? drawnPath : routeCoords
        guard !path.isEmpty else {
            routeError = "Nothing to export — build, draw, or import a route first."
            return
        }
        let gpx = GPXCodec.export(path)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Locus-Route.gpx")
        // The planner is up while this runs, so failures go to its own error row.

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
            routeError = error.localizedDescription
        }
    }
}

/// The endpoints a loaded route was built from. CLLocationCoordinate2D is not Equatable,
/// and the comparison wants exact identity rather than a tolerance — this is asking "is
/// this the same request", not "are these nearby".
private struct RouteEndpoints: Equatable {
    var startLatitude: Double
    var startLongitude: Double
    var endLatitude: Double
    var endLongitude: Double

    init(start: CLLocationCoordinate2D, end: CLLocationCoordinate2D) {
        startLatitude = start.latitude
        startLongitude = start.longitude
        endLatitude = end.latitude
        endLongitude = end.longitude
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
