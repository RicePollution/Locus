import CoreLocation
import Foundation
import MapKit
import UIKit
import UserNotifications

enum TravelMode: String, CaseIterable, Identifiable {
    case walk, run, cycle, drive

    var id: String { rawValue }

    var title: String {
        switch self {
        case .walk: return "Walk"
        case .run: return "Run"
        case .cycle: return "Cycle"
        case .drive: return "Drive"
        }
    }

    var icon: String {
        switch self {
        case .walk: return "figure.walk"
        case .run: return "figure.run"
        case .cycle: return "bicycle"
        case .drive: return "car.fill"
        }
    }

    /// Base meters per second before natural variation.
    var baseSpeed: CLLocationSpeed {
        switch self {
        case .walk: return 1.4
        case .run: return 3.3
        case .cycle: return 6.5
        case .drive: return 13.4
        }
    }

    var mkTransportType: MKDirectionsTransportType {
        switch self {
        case .walk, .run: return .walking
        case .cycle, .drive: return .automobile
        }
    }
}

enum SpoofStatus: Equatable {
    case idle
    case connecting
    case active
    case reconnecting
    case dropped(String)

    var label: String {
        switch self {
        case .idle: return "Not Spoofing"
        case .connecting: return "Starting…"
        case .active: return "Spoofing"
        case .reconnecting: return "Reconnecting…"
        case .dropped: return "Interrupted"
        }
    }

    var isDropped: Bool {
        if case .dropped = self { return true }
        return false
    }
}

@MainActor
final class SpoofSession: ObservableObject {
    @Published var status: SpoofStatus = .idle
    @Published var pin: CLLocationCoordinate2D?
    /// What the engine has actually confirmed — this is what the UI renders.
    @Published var simulated: CLLocationCoordinate2D?
    @Published var travelMode: TravelMode = .walk
    @Published var mapStyleIndex: Int = 0
    @Published var lastError: String?
    @Published var isBusy = false
    @Published var joystickActive = false
    /// True while a route is being followed. Exposed because the planner has to tell the
    /// difference between "the user changed their mind about the start" and "the start
    /// moved because playback is moving it" — those look identical from the outside and
    /// mean opposite things.
    @Published private(set) var isFollowingRoute = false
    /// The limit in force at the current step, or nil when no route is running. Assigned
    /// only when the value actually changes — the follower steps ~3×/s and a zone boundary
    /// arrives perhaps twice a minute, so an unconditional assignment would redraw the
    /// status chrome 180 times per useful update.
    @Published private(set) var currentSpeedLimit: SpeedReading?
    /// Bumped on every Stop. A Follow can be waiting on a speed-limit lookup when Stop is
    /// tapped, and at that moment there is no `routeTask` for Stop to cancel — so the follow
    /// that gesture was cancelling would start behind it. Comparing this across the wait is
    /// what lets the caller close that window.
    private(set) var stopGeneration = 0

    /// Tunnel IP the engine has actually reached, and the port it reached it on.
    @Published private(set) var confirmedTunnelIP: String?
    /// Tunnel IPs that have answered at least once this process. `LocalDevVPN`'s interface
    /// scan produces false negatives for loopback-mode proxies, so one success is standing
    /// proof that a later negative scan for that IP means nothing. Unlike
    /// `confirmedTunnelIP` this is never retracted: it describes the setup, not the link.
    @Published private(set) var provenTunnelIPs: Set<String> = []
    @Published private(set) var activePort: UInt16?
    /// The last port that actually carried a tunnel, kept after the session ends. The live
    /// `activePort` is cleared on stop, which hid the number at exactly the moment a user
    /// diagnosing a dead tunnel needs it. Never retracted; it is a diagnostic, not a claim.
    @Published private(set) var lastTunnelPort: UInt16?

    @Published var favorites: [SavedPlace] = []
    @Published var recents: [SavedPlace] = []

    private enum IntentSource {
        case user, resend, motion
    }

    private enum EngineIntent {
        case apply(coordinate: CLLocationCoordinate2D, markRecent: Bool, source: IntentSource)
        case clear
    }

    /// Where the user wants to be, as opposed to where the engine has got to. The resend
    /// and the joystick read this, so a slow engine call can't resurrect a stale fix.
    private var desired: CLLocationCoordinate2D?
    private var pending: EngineIntent?
    private var inFlight = false
    private var consecutiveFailures = 0
    private var dropNotified = false
    private var pairingStore: PairingStore?
    private let dropThreshold = 3

    private var resendTimer: Timer?
    private var joystickTimer: Timer?
    private var routeTask: Task<Void, Never>?
    /// Bumped on every `followRoute`. A cancelled run's cleanup would otherwise clear
    /// `isFollowingRoute` after its replacement had already set it, leaving the planner
    /// convinced nothing is playing while a route runs.
    private var routeGeneration = 0
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    private var joystickVector: CGVector = .zero
    private let locationKeeper = BackgroundKeepAlive()

    private let favoritesKey = "locus.favorites"
    private let recentsKey = "locus.recents"

    init() {
        favorites = SavedPlace.load(key: favoritesKey)
        recents = SavedPlace.load(key: recentsKey)
    }

    var isSpoofing: Bool {
        if case .active = status { return true }
        if case .reconnecting = status { return true }
        return false
    }

    func teleport(to coordinate: CLLocationCoordinate2D, pairing: PairingStore) {
        guard pairing.hasPairingFile else {
            lastError = "Import an RPPairing file in Settings first."
            return
        }
        pin = coordinate
        request(coordinate, pairing: pairing, markRecent: true, source: .user)
    }

    func stop(pairing: PairingStore) {
        stopGeneration += 1
        routeTask?.cancel()
        routeTask = nil
        isFollowingRoute = false
        stopJoystick()
        stopResend()
        // Drop the intent before the clear lands so an in-flight apply can't re-arm it.
        desired = nil
        enqueue(.clear, pairing: pairing)
    }

    /// Best-known real device coordinate (not the teleport pin).
    var realCoordinate: CLLocationCoordinate2D? {
        locationKeeper.lastKnownCoordinate
    }

    /// Where the device actually is, as last seen with nothing simulated.
    ///
    /// Not `realCoordinate`. The keeper reports whatever `locationd` reports, and once a
    /// spoof is running that is the *simulated* fix fed back to us — so the live value stops
    /// describing the device and starts describing the lie. Anything reasoning about the
    /// user's real position has to read this instead, and it refreshes only while `simulated`
    /// is nil, which freezes it for the length of a session and releases it on stop.
    ///
    /// Freezing loses nothing: while spoofing, the app has no way to know the real position
    /// anyway, and nothing it could send describes it, because the route starts from the
    /// simulated point.
    ///
    /// Coarse by construction — the keeper asks for `kCLLocationAccuracyThreeKilometers` —
    /// which is fine for an exclusion radius but is why no user-facing string may claim to
    /// know exactly where the device is.
    private(set) var lastUnspoofedCoordinate: CLLocationCoordinate2D?

    /// The anchor the speed-limit exclusion is measured from, refreshed if and only if
    /// nothing is currently simulated.
    func exclusionAnchor() -> CLLocationCoordinate2D? {
        if simulated == nil, let current = locationKeeper.lastKnownCoordinate {
            lastUnspoofedCoordinate = current
        }
        return lastUnspoofedCoordinate
    }

    /// Start lightweight GPS updates for the map puck / locate button.
    func startLocationUpdates() {
        locationKeeper.start()
    }

    func startJoystick(pairing: PairingStore) {
        guard pairing.hasPairingFile else {
            lastError = "Import an RPPairing file in Settings first."
            return
        }
        let start = simulated ?? pin ?? locationKeeper.lastKnownCoordinate
        guard let start else {
            lastError = "Drop a pin or teleport somewhere before using the joystick."
            return
        }
        if simulated == nil {
            request(start, pairing: pairing, markRecent: false, source: .user)
        }
        joystickActive = true
        joystickTimer?.invalidate()
        joystickTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tickJoystick(pairing: pairing)
            }
        }
    }

    func updateJoystick(vector: CGVector) {
        joystickVector = vector
    }

    func stopJoystick() {
        joystickActive = false
        joystickVector = .zero
        joystickTimer?.invalidate()
        joystickTimer = nil
    }

    /// `profile` defaults to nil so the GPX and drawn-path call sites need no change, and so
    /// a route that outran its speed-limit lookup still follows — at the old fixed speed.
    func followRoute(
        _ coordinates: [CLLocationCoordinate2D],
        profile: SpeedProfile? = nil,
        pairing: PairingStore
    ) {
        guard pairing.hasPairingFile, coordinates.count >= 2 else { return }
        routeTask?.cancel()
        stopJoystick()
        let mode = travelMode
        isFollowingRoute = true
        currentSpeedLimit = nil
        routeGeneration += 1
        let generation = routeGeneration
        routeTask = Task { [weak self] in
            guard let self else { return }
            defer {
                Task { @MainActor [weak self] in
                    guard let self, self.routeGeneration == generation else { return }
                    self.isFollowingRoute = false
                    self.currentSpeedLimit = nil
                }
            }
            await MainActor.run {
                self.request(coordinates[0], pairing: pairing, markRecent: true, source: .user)
            }
            // The pacer owns the profile by value, so a lookup that installs a different one
            // mid-run cannot mutate what this Task is walking.
            var pacer = RoutePacer(coordinates: coordinates, profile: profile, mode: mode)
            while let step = pacer.next() {
                if Task.isCancelled { break }
                try? await Task.sleep(nanoseconds: UInt64(step.delay * 1_000_000_000))
                // try? swallows the CancellationError, so re-check: without this the
                // step after a Stop still runs, and its apply can be drained after the
                // clear completes and quietly restart the whole session.
                if Task.isCancelled { break }
                await MainActor.run {
                    if self.currentSpeedLimit != step.reading {
                        self.currentSpeedLimit = step.reading
                    }
                    self.request(step.coordinate, pairing: pairing, markRecent: false, source: .motion)
                }
            }
        }
    }

    func addFavorite(name: String, coordinate: CLLocationCoordinate2D) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let place = SavedPlace(
            name: trimmed.isEmpty ? Self.coordinateLabel(coordinate) : trimmed,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        )
        // Don't let a generic star overwrite a named favorite for the same spot.
        if let existing = favorites.first(where: { $0.id == place.id }),
           Self.isGenericFavoriteName(place.name),
           !Self.isGenericFavoriteName(existing.name) {
            return
        }
        favorites.removeAll { $0.id == place.id }
        favorites.insert(place, at: 0)
        SavedPlace.save(favorites, key: favoritesKey)
    }

    func renameFavorite(_ place: SavedPlace, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = favorites.firstIndex(where: { $0.id == place.id }) else { return }
        favorites[index].name = trimmed
        SavedPlace.save(favorites, key: favoritesKey)
    }

    func removeFavorite(_ place: SavedPlace) {
        favorites.removeAll { $0.id == place.id }
        SavedPlace.save(favorites, key: favoritesKey)
    }

    func removeRecent(_ place: SavedPlace) {
        recents.removeAll { $0.id == place.id }
        SavedPlace.save(recents, key: recentsKey)
    }

    /// Best display name for starring the current pin (search title, matching recent, etc.).
    func suggestedFavoriteName(for coordinate: CLLocationCoordinate2D, fallback: String? = nil) -> String {
        if let fallback, !fallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let favorite = favorites.first(where: { $0.id == SavedPlace(name: "", latitude: coordinate.latitude, longitude: coordinate.longitude).id }),
           !Self.isGenericFavoriteName(favorite.name) {
            return favorite.name
        }
        if let recent = recents.first(where: {
            abs($0.latitude - coordinate.latitude) < 0.00015 && abs($0.longitude - coordinate.longitude) < 0.00015
        }), !Self.isGenericFavoriteName(recent.name) {
            return recent.name
        }
        return Self.coordinateLabel(coordinate)
    }

    private static func coordinateLabel(_ coordinate: CLLocationCoordinate2D) -> String {
        String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude)
    }

    private static func isGenericFavoriteName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "Favorite" { return true }
        // Coordinate-looking labels from older teleports.
        let parts = trimmed.split(separator: ",")
        if parts.count == 2,
           Double(parts[0].trimmingCharacters(in: .whitespaces)) != nil,
           Double(parts[1].trimmingCharacters(in: .whitespaces)) != nil {
            return true
        }
        return false
    }

    /// The one place `desired` is written: every coordinate the app wants funnels here.
    private func request(_ coordinate: CLLocationCoordinate2D, pairing: PairingStore, markRecent: Bool, source: IntentSource) {
        desired = coordinate
        enqueue(.apply(coordinate: coordinate, markRecent: markRecent, source: source), pairing: pairing)
    }

    /// Latest-wins: the engine is slow and the joystick ticks four times a second, so
    /// only the newest intent is ever worth running.
    private func enqueue(_ intent: EngineIntent, pairing: PairingStore) {
        pairingStore = pairing
        if case .apply = intent, case .clear = pending {
            // A queued stop outranks any coordinate that arrives behind it.
            return
        }
        pending = intent
        guard !inFlight else { return }
        inFlight = true
        Task { await drain() }
    }

    private func drain() async {
        defer { inFlight = false }
        while let intent = pending {
            pending = nil
            switch intent {
            case .apply(let coordinate, let markRecent, let source):
                await runApply(coordinate, markRecent: markRecent, source: source)
            case .clear:
                await runClear()
            }
        }
    }

    private func runApply(_ coordinate: CLLocationCoordinate2D, markRecent: Bool, source: IntentSource) async {
        // enqueue() records the store before any drain can start, so this never fires.
        guard let pairing = pairingStore else { return }
        if status.isDropped {
            status = .reconnecting
        } else if status == .idle {
            status = .connecting
        }
        isBusy = true
        // Read the target once: the user can save a different tunnel IP in Settings while
        // this is in flight, and the result belongs to the address we actually dialled.
        let requestedIP = TunnelConfig.targetIP
        let result = await LocationEngine.set(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            pairingPath: pairing.pairingPath,
            deviceIP: requestedIP
        )
        isBusy = false
        // A stop arrived while this was in flight — let it own the status so Stop can't flash green.
        if case .clear = pending { return }


        switch result {
        case .success(let applied):
            simulated = coordinate
            pin = coordinate
            activePort = applied.port
            lastTunnelPort = applied.port
            confirmedTunnelIP = requestedIP
            provenTunnelIPs.insert(requestedIP)
            consecutiveFailures = 0
            dropNotified = false
            status = .active
            if source == .user {
                lastError = nil
            }
            beginBackground()
            locationKeeper.start()
            startResend(pairing: pairing)
            if markRecent {
                pushRecent(coordinate)
            }
        case .failure(let error):
            // Only a user gesture may raise the alert; a failing 8s resend would otherwise
            // pop a modal every 8 seconds.
            if source == .user {
                lastError = error.localizedDescription
            }
            // A tunnel-layer refusal disproves reachability. A failure further up the
            // chain (RSD, simulation, set) still proves the tunnel itself answered, so
            // it must not retract the evidence.
            switch error {
            case .tunnelCreate, .portUnavailable:
                confirmedTunnelIP = nil
            default:
                break
            }
            if simulated == nil {
                // Nothing ever came up, so there is no session to reconnect to — and the
                // producer has to stop as well. A route left running would otherwise feed
                // the engine a full candidate sweep per step, for the whole route, while
                // the UI reads "Not Spoofing" and the drop threshold never trips.
                desired = nil
                routeTask?.cancel()
                routeTask = nil
                isFollowingRoute = false
                currentSpeedLimit = nil
                stopJoystick()
            }
            consecutiveFailures += 1
            guard desired != nil else {
                consecutiveFailures = 0
                status = .idle
                return
            }
            if consecutiveFailures >= dropThreshold {
                status = .dropped(error.localizedDescription)
                if !dropNotified {
                    dropNotified = true
                    postDropNotification(error.localizedDescription)
                }
            } else {
                status = .reconnecting
            }
        }
    }

    /// Stop always lands in `.idle`: the handles are freed either way and the user asked
    /// to stop, so a failure here is worth an error but never a dropped-session badge.
    private func runClear() async {
        isBusy = true
        let result = await LocationEngine.clear()
        isBusy = false
        desired = nil
        simulated = nil
        currentSpeedLimit = nil
        activePort = nil
        // Reachability is evidence of a *current* tunnel, not a memory of one. Leaving
        // this set pins the status chip to "Connected" for the life of the process.
        confirmedTunnelIP = nil
        consecutiveFailures = 0
        dropNotified = false
        status = .idle
        endBackground()
        // Keep location updates running so the map puck / locate button
        // can return to the real GPS fix (not the leftover pin).
        locationKeeper.start()
        if case .failure(let error) = result {
            lastError = error.localizedDescription
        }
    }

    private func tickJoystick(pairing: PairingStore) {
        guard joystickActive, let current = desired else { return }
        let magnitude = hypot(joystickVector.dx, joystickVector.dy)
        guard magnitude > 0.08 else { return }
        let nx = joystickVector.dx / magnitude
        let ny = -joystickVector.dy / magnitude
        let speed = travelMode.baseSpeed * min(1.0, magnitude) * Double.random(in: 0.9...1.1)
        let dt = 0.25
        let meters = speed * dt
        let next = offset(coordinate: current, eastMeters: nx * meters, northMeters: ny * meters)
        request(next, pairing: pairing, markRecent: false, source: .motion)
    }

    /// Re-asserts the fix every 8s — iOS drops it otherwise. It keeps firing while the
    /// session is `.dropped`, which is also what brings a broken tunnel back.
    ///
    /// The interval is `ResendSettings.interval` rather than a literal so the gap can be
    /// stretched to measure whether an idle tunnel survives; see that type. It is read once
    /// here, so a change taken in Settings applies from the next teleport, not mid-session.
    private func startResend(pairing: PairingStore) {
        resendTimer?.invalidate()
        resendTimer = Timer.scheduledTimer(withTimeInterval: ResendSettings.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let target = self.desired else { return }
                self.enqueue(
                    .apply(coordinate: target, markRecent: false, source: .resend),
                    pairing: pairing
                )
            }
        }
    }

    private func stopResend() {
        resendTimer?.invalidate()
        resendTimer = nil
    }

    private func pushRecent(_ coordinate: CLLocationCoordinate2D) {
        pushNamedRecent(
            name: Self.coordinateLabel(coordinate),
            coordinate: coordinate
        )
    }

    func pushNamedRecent(name: String, coordinate: CLLocationCoordinate2D) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let place = SavedPlace(
            name: trimmed.isEmpty ? Self.coordinateLabel(coordinate) : trimmed,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        )
        recents.removeAll {
            abs($0.latitude - place.latitude) < 0.00015 && abs($0.longitude - place.longitude) < 0.00015
        }
        recents.insert(place, at: 0)
        if recents.count > 20 { recents = Array(recents.prefix(20)) }
        SavedPlace.save(recents, key: recentsKey)
    }

    private func beginBackground() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask { [weak self] in
            self?.endBackground()
        }
    }

    private func endBackground() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private func postDropNotification(_ message: String) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let content = UNMutableNotificationContent()
        content.title = "Locus spoof dropped"
        content.body = message
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func offset(coordinate: CLLocationCoordinate2D, eastMeters: Double, northMeters: Double) -> CLLocationCoordinate2D {
        let earth = 6378137.0
        let dLat = northMeters / earth * (180 / .pi)
        let dLon = eastMeters / (earth * cos(coordinate.latitude * .pi / 180)) * (180 / .pi)
        return CLLocationCoordinate2D(latitude: coordinate.latitude + dLat, longitude: coordinate.longitude + dLon)
    }
}

/// How often a running session re-asserts its fix.
///
/// 8s is the shipped cadence and the only one meant for real use: iOS expires a simulated
/// fix that nothing renews, so a longer gap lets the device drift back to its real position
/// between ticks. This is adjustable to answer exactly one question — does an idle developer
/// tunnel survive, or does `remoted` hang up on a channel nobody is using?
///
/// That answer decides whether holding a tunnel open across a Stop (an "armed" state) is
/// worth building: arming is only useful if the channel is still alive when you reach for it
/// later. Stretching this interval and watching the next resend is the cheapest way to
/// measure it, and the two outcomes are distinguishable — a merely lapsed fix re-asserts
/// cleanly on the same handle, whereas a dead channel fails and drops the session.
enum ResendSettings {
    static let defaultsKey = "locus.resendInterval"

    /// The shipped cadence. Anything else is a diagnostic and will visibly lapse.
    static let standard: TimeInterval = 8

    /// Offered gaps, bracketing a plausible idle timeout.
    static let options: [TimeInterval] = [8, 60, 180, 600]

    static var interval: TimeInterval {
        // `double(forKey:)` reports 0 for a missing key, and a value left over from an older
        // build could strand the session on a cadence the picker cannot display or undo.
        let stored = UserDefaults.standard.double(forKey: defaultsKey)
        return options.contains(stored) ? stored : standard
    }

    static func setInterval(_ value: TimeInterval) {
        UserDefaults.standard.set(value, forKey: defaultsKey)
    }

    static var isDiagnostic: Bool { interval != standard }
}
