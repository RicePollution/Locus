import CoreLocation
import Foundation
import os

/// One way as Overpass returned it, after decoding and before matching.
struct OSMWay {
    let id: Int64
    let tags: [String: String]
    /// Full way geometry in order. May be shorter than what Overpass sent: entries that
    /// decode to null are dropped and the way is split at the gap.
    let geometry: [CLLocationCoordinate2D]
}

/// File-scope rather than nested in the actor so `OverpassRequest` can raise the same cases.
private enum LookupFailure: Error {
    case throttled(retryAfter: TimeInterval?)
    case serverBusy
    case rejected
    case unavailable(String)

    var reason: String {
        switch self {
        case .throttled, .serverBusy: return "server busy"
        case .rejected: return "query rejected"
        case .unavailable(let text): return text
        }
    }
}

/// Fetches and builds the posted-limit profile for a route.
///
/// An `actor` rather than the `enum` namespace the rest of `Engine/` uses, so the ~100 ms
/// matching pass runs off the main actor without a `Task.detached` at every call site.
actor SpeedLimitService {
    static let shared = SpeedLimitService()

    /// Never throws. A missing profile is a state the planner reports, not an error the user
    /// has to dismiss — `session.lastError` raises a modal alert, and a busy volunteer server
    /// must not put a modal in front of someone who just wanted to drive down a road.
    enum Outcome {
        case profile(SpeedProfile)
        /// The Settings toggle is off.
        case disabled
        /// Structurally not applicable: wrong travel mode, the route is over the length cap,
        /// or nothing of it may be sent.
        case notApplicable(reason: String)
        /// We tried and could not get it: offline, throttled, server error, nothing returned.
        case unavailable(reason: String)
    }

    // Tuning. Every one of these is a number an implementer would otherwise invent.
    static let endpoint = URL(string: "https://overpass-api.de/api/interpreter")!
    static let serverTimeout = 25              // the [timeout:N] inside the QL
    static let requestTimeout: TimeInterval = 30
    static let resourceTimeout: TimeInterval = 60
    /// Has to clear what a route at `maxRouteLength` can legitimately return, or the cap
    /// rejects valid answers instead of catching abusive ones. The design's worst measured
    /// density is ~18 KB/km (midtown Manhattan), so 150 km is ~2.7 MB; 4 MB is that with
    /// headroom. These two numbers are bound together — lowering this one without lowering
    /// `maxRouteLength` reintroduces the mismatch.
    static let maxResponseBytes = 4 * 1024 * 1024
    static let maxRouteLength: CLLocationDistance = 150_000
    static let retryDelays: [TimeInterval] = [2, 6]
    static let throttleCooldown: TimeInterval = 60
    /// Longest an honoured `Retry-After` may hold a lookup.
    static let maxRetryAfter: TimeInterval = 15
    /// Floor on the gap between two requests. Politeness, and the only *structural* bound on
    /// how fast this app can ask a volunteer server for anything.
    static let minimumRequestInterval: TimeInterval = 2
    static let cacheLimit = 8
    /// No point this close to where the device physically is may be sent.
    ///
    /// A route's start is very often exactly that: `resolvedRouteStart` falls through to
    /// `session.realCoordinate` when nothing is simulated yet, so a first Build would
    /// otherwise upload the user's actual position at ~1.1 m precision next to their IP.
    static let realLocationRadius: CLLocationDistance = 500
    /// Most corridors one query may union. A route weaving in and out of the exclusion could
    /// otherwise build a union of dozens of statements against a volunteer server.
    static let maxQueryRuns = 8

    /// Overpass's usage policy asks for an identifying agent. `User-Agent` is not a reserved
    /// header on iOS and is sent as written — which also means the server knows this is Locus.
    static let userAgent: String = {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        return "Locus/\(version) (+https://github.com/RicePollution/Locus)"
    }()

    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.ricepollution.locus",
        category: "speedlimits"
    )

    /// Tags whose values can carry a country prefix. Read for unit inference only.
    private static let countryHintTags = ["maxspeed", "maxspeed:type", "source:maxspeed", "zone:maxspeed"]

    private struct CacheEntry {
        let key: Int
        let profile: SpeedProfile
    }

    /// Process-lifetime only, no disk: Overpass sends no useful cache headers, so `URLCache`
    /// would do nothing.
    private var cache: [CacheEntry] = []
    /// Set by a second 429. Until it lapses every lookup short-circuits with no request at
    /// all, which is the whole point — a throttled server must not be asked again.
    private var cooldownUntil: Date?
    /// Earliest instant the next request may leave. Each lookup reserves its slot with no
    /// `await` between the read and the write, so reentrant calls queue instead of colliding.
    ///
    /// This is what actually bounds the request rate. Actor isolation does not: actors are
    /// reentrant at every suspension point. `httpMaximumConnectionsPerHost = 1` does not
    /// either — it bounds TCP connections, and HTTP/2 multiplexes requests over one. And
    /// cancelling a `URLSessionTask` does not stop Overpass computing a query it has already
    /// accepted, so "the user moved on" is not a reason the server stops paying for it.
    private var nextRequestAllowedAt = Date.distantPast

    /// A dedicated session, not `.shared`.
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = SpeedLimitService.requestTimeout
        config.timeoutIntervalForResource = SpeedLimitService.resourceTimeout
        // Offline must fail fast rather than queue behind connectivity that may never come.
        config.waitsForConnectivity = false
        // Respect Low Data Mode: the user gets the fallback rather than the bill.
        config.allowsConstrainedNetworkAccess = false
        config.httpMaximumConnectionsPerHost = 1
        config.httpAdditionalHeaders = ["User-Agent": SpeedLimitService.userAgent]
        return URLSession(configuration: config)
    }()

    /// `realCoordinate` is the device's actual position, and every point within
    /// `realLocationRadius` of it is withheld from the query — see `runs(in:excluding:)`.
    func profile(
        for route: RoadRoute,
        mode: TravelMode,
        excluding realCoordinate: CLLocationCoordinate2D?
    ) async -> Outcome {
        guard SpeedLimitSettings.isEnabled else { return .disabled }
        // §3.6: a posted car limit is not a pedestrian's speed, and the query asks only for
        // drivable classes, so a walking route would match nothing and waste the request.
        guard mode == .drive else {
            return .notApplicable(reason: "only driving routes use posted limits")
        }
        guard route.coordinates.count >= 2 else {
            return .notApplicable(reason: "this route has no path to match")
        }
        guard route.distance <= Self.maxRouteLength else {
            return .notApplicable(reason: "route too long (over \(Int(Self.maxRouteLength / 1000)) km)")
        }

        let decimated = SpeedLimitMatcher.decimate(
            route.coordinates,
            tolerance: SpeedLimitMatcher.decimationTolerance,
            limit: SpeedLimitMatcher.decimationLimit
        )
        // Derived from the tolerance decimation actually reached, never a constant: the
        // corridor has to cover the full polyline, not the decimated one.
        let radius = SpeedLimitMatcher.queryRadius(forTolerance: decimated.tolerance)
        guard decimated.coordinates.count >= 2 else {
            return .notApplicable(reason: "this route has no path to match")
        }
        let runs = Self.runs(in: decimated.coordinates, excluding: realCoordinate, radius: radius)
        guard !runs.isEmpty else {
            return .notApplicable(reason: "route stays too close to your device's own location")
        }

        let key = Self.cacheKey(for: runs, radius: radius)
        if let hit = cache.first(where: { $0.key == key })?.profile {
            return .profile(hit)
        }
        if let cooldownUntil, cooldownUntil > Date() {
            return .unavailable(reason: "server busy")
        }
        guard await reserveRequestSlot() else { return .unavailable(reason: "cancelled") }

        let ways: [OSMWay]
        do {
            ways = try Self.decodeWays(try await send(Self.query(for: runs, radius: radius)))
        } catch let failure as LookupFailure {
            return .unavailable(reason: failure.reason)
        } catch {
            return .unavailable(reason: Self.reason(for: error))
        }
        guard !ways.isEmpty else { return .unavailable(reason: "no roads found near this route") }

        let fallback = route.averageSpeed ?? mode.baseSpeed
        let profile = SpeedLimitMatcher.profile(
            route: route.coordinates,
            ways: ways,
            // Inferred from the stretches that were actually queried, so the reverse-geocode
            // fallback obeys the same exclusion the request does rather than handing the
            // user's real position to a second service.
            unit: await inferUnit(from: ways, sampledFrom: runs),
            fallback: fallback,
            fallbackSource: route.averageSpeed != nil ? .routeAverage : .travelMode
        )
        cache.removeAll { $0.key == key }
        cache.append(CacheEntry(key: key, profile: profile))
        if cache.count > Self.cacheLimit {
            cache.removeFirst(cache.count - Self.cacheLimit)
        }
        return .profile(profile)
    }

    /// Claims the next send slot and waits for it. False only when the wait was cancelled.
    ///
    /// Waiting rather than refusing: a second route selection is a legitimate gesture, and
    /// answering it with "unavailable, try again" would leave that route without a profile
    /// for good. A caller that has moved on cancels, and its wait dies here.
    private func reserveRequestSlot() async -> Bool {
        let now = Date()
        let slot = max(now, nextRequestAllowedAt)
        let previous = nextRequestAllowedAt
        let claimed = slot.addingTimeInterval(Self.minimumRequestInterval)
        nextRequestAllowedAt = claimed
        let wait = min(slot.timeIntervalSince(now), 30)
        guard wait > 0 else { return true }
        do {
            try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        } catch {
            // Nothing went out, so the slot this call took has to go back. Without the
            // rollback a run of abandoned selections walks the gate forward and delays a
            // later request that never competed with anything. Only if nobody has claimed a
            // slot behind us in the meantime — theirs is still pending and still owed.
            if nextRequestAllowedAt == claimed { nextRequestAllowedAt = previous }
            return false
        }
        return true
    }

    // MARK: - Network

    private func send(_ query: String) async throws -> Data {
        var busyRetries = 0
        var throttles = 0
        while true {
            do {
                return try await perform(query)
            } catch let failure as LookupFailure {
                switch failure {
                case .throttled(let retryAfter):
                    throttles += 1
                    guard throttles < 2 else {
                        // A second 429 is the server saying stop. Short-circuit every lookup
                        // for a minute rather than asking again and making it worse.
                        cooldownUntil = Date().addingTimeInterval(Self.throttleCooldown)
                        throw failure
                    }
                    try await Task.sleep(nanoseconds: UInt64((retryAfter ?? 5) * 1_000_000_000))
                case .serverBusy:
                    guard busyRetries < Self.retryDelays.count else { throw failure }
                    let delay = Self.retryDelays[busyRetries] * Double.random(in: 0.75...1.25)
                    busyRetries += 1
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                default:
                    throw failure
                }
            }
        }
    }

    private func perform(_ query: String) async throws -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw LookupFailure.rejected
        }
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = Data("data=\(encoded)".utf8)

        let (http, body) = try await OverpassRequest(limit: Self.maxResponseBytes)
            .run(request, in: session)
        switch http.statusCode {
        case 200:
            return body
        case 429:
            throw LookupFailure.throttled(retryAfter: Self.retryAfter(http))
        case 300...399:
            // The delegate refused a redirect off the endpoint's host, so the task finished
            // holding the 3xx itself.
            throw LookupFailure.unavailable("unexpected redirect")
        case 500...599:
            // An overloaded dispatcher answers 504 with an HTML body, twice in seven
            // requests during the design probes. Worth retrying; nothing else here is.
            throw LookupFailure.serverBusy
        default:
            // A 4xx is our own query being wrong. Retrying our bug wastes a volunteer's
            // cycles, so log enough to fix it and give up. The body stays private: Overpass
            // quotes the offending query back, and the query is the route corridor.
            let text = String(decoding: body.prefix(500), as: UTF8.self)
            Self.log.error("Overpass rejected the query (\(http.statusCode, privacy: .public)): \(text, privacy: .private)")
            throw LookupFailure.rejected
        }
    }

    /// `Retry-After` is text the server chooses. `TimeInterval("nan")` and `"-1"` both parse,
    /// and NaN survives `min` — which is `Comparable`, not IEEE — all the way into
    /// `UInt64(_:)`, which traps. The finiteness gate has to come before the clamp, not after.
    static func retryAfter(_ response: HTTPURLResponse) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After"),
              let seconds = TimeInterval(raw),
              seconds.isFinite, seconds >= 0 else { return nil }
        return min(seconds, maxRetryAfter)
    }

    private static func reason(for error: Error) -> String {
        guard let urlError = error as? URLError else {
            return error is CancellationError ? "cancelled" : "lookup failed"
        }
        if urlError.networkUnavailableReason == .constrained { return "Low Data Mode" }
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
             .cannotConnectToHost, .dataNotAllowed, .internationalRoamingOff:
            return "offline"
        case .timedOut:
            return "timed out"
        case .cancelled:
            return "cancelled"
        default:
            return "network error"
        }
    }

    // MARK: - Query

    /// The stretches of a decimated polyline that may be sent, split at the exclusion around
    /// the device's real position.
    ///
    /// Excluded stretches are *not* bridged. Joining the surviving neighbours would draw the
    /// corridor straight across the gap and query the roads around the user's home anyway,
    /// which is the thing being prevented. Each surviving run becomes its own `around` filter
    /// inside one union, and the dropped stretches resolve through the fallback chain exactly
    /// like a stretch the corridor missed for any other reason.
    static func runs(
        in coordinates: [CLLocationCoordinate2D],
        excluding real: CLLocationCoordinate2D?,
        radius: Int
    ) -> [[CLLocationCoordinate2D]] {
        guard let real, real.latitude.isFinite, real.longitude.isFinite else {
            return coordinates.count >= 2 ? [coordinates] : []
        }
        // Measured to the SEGMENT, not to the vertices, and against the exclusion plus the
        // corridor's own radius. Testing vertices is the intuitive version and it does not
        // work: Douglas–Peucker collapses a straight road to its two endpoints, so a route
        // that runs past the device on a straight stretch has no vertex near it to split on,
        // and the corridor Overpass draws between those two distant vertices still sweeps
        // the street outside the door. Adding `radius` is what makes the exclusion cover the
        // corridor rather than its centre line.
        let threshold = realLocationRadius + Double(radius)
        var runs: [[CLLocationCoordinate2D]] = []
        var current: [CLLocationCoordinate2D] = coordinates.isEmpty ? [] : [coordinates[0]]
        for (a, b) in zip(coordinates, coordinates.dropFirst()) {
            guard SpeedLimitMatcher.distance(from: real, toSegment: a, b) > threshold else {
                // This leg may not be sent, so the run ends here and the next one starts on
                // the far side. A vertex inside the threshold is covered for free: both of
                // its legs break, leaving it alone in a run of one, which is dropped below.
                if current.count >= 2 { runs.append(current) }
                current = [b]
                continue
            }
            current.append(b)
        }
        if current.count >= 2 { runs.append(current) }
        guard runs.count > maxQueryRuns else { return runs }
        // The shortest stretches contribute least and fall through the chain like any other
        // gap. Kept in route order so the query reads the way the route does.
        let kept = runs.enumerated()
            .sorted { $0.element.count > $1.element.count }
            .prefix(maxQueryRuns)
            .sorted { $0.offset < $1.offset }
        return kept.map(\.element)
    }

    /// `around` with a coordinate list is a corridor around the *chord* between the points,
    /// not around the road, which is why the polyline handed in must be Douglas–Peucker
    /// decimated rather than uniformly sampled.
    static func query(for runs: [[CLLocationCoordinate2D]], radius: Int) -> String {
        let filter = """
              way["highway"~"^(motorway|trunk|primary|secondary|tertiary|unclassified\
            |residential|living_street|service|motorway_link|trunk_link|primary_link\
            |secondary_link|tertiary_link)$"]
                ["service"!~"^(parking_aisle|driveway|drive-through|emergency_access)$"]
                ["area"!="yes"]
            """
        var body = "[out:json][timeout:\(serverTimeout)][maxsize:67108864];\n"
        if runs.count > 1 { body += "(\n" }
        for run in runs {
            body += filter
            body += "\n    (around:\(radius)"
            for coordinate in run {
                // %.5f is ~1.1 m. Finer is wasted bytes and leaks nothing useful.
                body += String(format: ",%.5f,%.5f", coordinate.latitude, coordinate.longitude)
            }
            body += ");\n"
        }
        if runs.count > 1 { body += ");\n" }
        body += "out tags geom;"
        return body
    }

    /// Hand-walked rather than `Codable`: every field here is attacker-controlled as far as
    /// this app is concerned, and a malformed element must be skipped rather than fail the
    /// whole decode.
    private static func decodeWays(_ data: Data) throws -> [OSMWay] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let elements = root["elements"] as? [Any] else {
            throw LookupFailure.unavailable("unreadable response")
        }
        var ways: [OSMWay] = []
        for element in elements {
            guard let dictionary = element as? [String: Any],
                  dictionary["type"] as? String == "way" else { continue }
            let id = (dictionary["id"] as? NSNumber)?.int64Value ?? 0
            let tags = (dictionary["tags"] as? [String: Any])?.compactMapValues { $0 as? String } ?? [:]
            let geometry = dictionary["geometry"] as? [Any] ?? []

            var run: [CLLocationCoordinate2D] = []
            run.reserveCapacity(geometry.count)
            for node in geometry {
                guard let point = node as? [String: Any],
                      let latitude = (point["lat"] as? NSNumber)?.doubleValue,
                      let longitude = (point["lon"] as? NSNumber)?.doubleValue,
                      latitude.isFinite, longitude.isFinite,
                      abs(latitude) <= 90, abs(longitude) <= 180 else {
                    // A null entry is a node Overpass did not return, so the way genuinely
                    // has a gap there. Bridging it would invent a straight segment across
                    // the gap and match route points to a road that is not there.
                    if run.count >= 2 { ways.append(OSMWay(id: id, tags: tags, geometry: run)) }
                    run.removeAll(keepingCapacity: true)
                    continue
                }
                run.append(CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
            }
            if run.count >= 2 { ways.append(OSMWay(id: id, tags: tags, geometry: run)) }
        }
        return ways
    }

    // MARK: - Unit inference

    /// Reads the route's own geography, never the device locale: `Locale.current` says
    /// nothing about where a spoofed route is.
    private func inferUnit(from ways: [OSMWay], sampledFrom runs: [[CLLocationCoordinate2D]]) async -> SpeedUnit {
        var prefixes: [String: Int] = [:]
        var sawMilesPerHour = false
        var sawBareNumber = false
        for way in ways {
            for tag in Self.countryHintTags {
                guard let value = way.tags[tag],
                      let country = MaxspeedParser.parse(value).countryHint else { continue }
                prefixes[country, default: 0] += 1
            }
            guard let maxspeed = way.tags["maxspeed"]?.lowercased()
                .trimmingCharacters(in: .whitespaces) else { continue }
            if maxspeed.hasSuffix("mph") { sawMilesPerHour = true }
            if Double(maxspeed) != nil { sawBareNumber = true }
        }

        // Ties broken by code so the same data always infers the same unit.
        let dominant = prefixes
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .first?.key
        if let dominant { return SpeedUnit.forCountryCode(dominant) }
        if sawMilesPerHour { return .milesPerHour }
        if sawBareNumber { return .kilometresPerHour }
        // Only reachable on a route with no `maxspeed` tag anywhere, so CLGeocoder's
        // throttling is not a risk.
        guard let longest = runs.max(by: { $0.count < $1.count }), !longest.isEmpty,
              let code = await Self.geocodedCountryCode(at: longest[longest.count / 2]) else {
            return .kilometresPerHour
        }
        return SpeedUnit.forCountryCode(code)
    }

    private static func geocodedCountryCode(at coordinate: CLLocationCoordinate2D) async -> String? {
        guard coordinate.latitude.isFinite, coordinate.longitude.isFinite else { return nil }
        let geocoder = CLGeocoder()
        // reverseGeocodeLocation has no timeout of its own, and a wedged request would hold
        // the whole lookup open. cancelGeocode is the only way to put a bound on it.
        let deadline = Task {
            do {
                try await Task.sleep(nanoseconds: 5_000_000_000)
            } catch {
                return
            }
            geocoder.cancelGeocode()
        }
        defer { deadline.cancel() }
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let placemarks = try? await geocoder.reverseGeocodeLocation(location)
        return placemarks?.first?.isoCountryCode
    }

    // MARK: - Cache key

    private static func cacheKey(for runs: [[CLLocationCoordinate2D]], radius: Int) -> Int {
        var hasher = Hasher()
        hasher.combine(radius)
        for run in runs {
            hasher.combine(run.count)
            for coordinate in run {
                // decimate() has already dropped non-finite coordinates; `Int(_:)` traps on
                // them rather than misbehaving, so this depends on that having happened.
                hasher.combine(Int((coordinate.latitude * 100_000).rounded()))
                hasher.combine(Int((coordinate.longitude * 100_000).rounded()))
            }
        }
        return hasher.finalize()
    }
}

/// One Overpass request.
///
/// A delegate-driven data task rather than `URLSession.bytes(for:)` for two reasons that both
/// need the delegate: a redirect must be refused before the POST body — which is the route
/// corridor — is replayed to whatever host the response names, and the response cap has to be
/// applied to real chunks, since a byte-at-a-time `AsyncBytes` loop is millions of async
/// iterations inside the actor, blocking every other lookup behind it.
private final class OverpassRequest: NSObject, URLSessionDataDelegate {
    private let limit: Int
    private let lock = NSLock()
    private var buffer = Data()
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<(HTTPURLResponse, Data), Error>?
    private var cancelled = false

    init(limit: Int) {
        self.limit = limit
        super.init()
    }

    func run(_ request: URLRequest, in session: URLSession) async throws -> (HTTPURLResponse, Data) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                guard !cancelled else {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                let task = session.dataTask(with: request)
                task.delegate = self
                self.task = task
                lock.unlock()
                task.resume()
                // A cancel landing between the unlock and the resume would have cancelled a
                // task that had not started, which on some releases delivers no completion
                // at all and leaves this continuation waiting for a callback that never
                // comes. Cancelling again after resume is idempotent and guarantees one.
                lock.lock()
                let cancelledDuringResume = cancelled
                lock.unlock()
                if cancelledDuringResume { task.cancel() }
            }
        } onCancel: {
            lock.lock()
            cancelled = true
            let task = self.task
            lock.unlock()
            task?.cancel()
        }
    }

    private func finish(_ result: Result<(HTTPURLResponse, Data), Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        // Releasing this side of the cycle is the whole fix, and it has to be this side. A
        // task retains its delegate and this object retains the task, and ARC does not
        // collect a cycle just because it has become unreachable — so without this every
        // lookup leaks one request object and one URLSessionTask for the life of the
        // process. Clearing the *task's* delegate instead is not an option: setting it after
        // `resume()` raises NSGenericException and takes the app down. Dropping this
        // reference is enough — the session releases the task on completion, the task then
        // releases its delegate, and both go.
        self.task = nil
        lock.unlock()
        // Nil on the second call: an overflow finishes the request before the task reports
        // its own completion, and only the first result is the answer.
        continuation?.resume(with: result)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        buffer.append(data)
        let overflowed = buffer.count > limit
        lock.unlock()
        guard overflowed else { return }
        // Cancelled mid-stream on purpose: a cap applied once the bytes are already resident
        // is not a cap.
        dataTask.cancel()
        finish(.failure(LookupFailure.unavailable("response too large")))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(.failure(error))
            return
        }
        guard let http = task.response as? HTTPURLResponse else {
            finish(.failure(LookupFailure.unavailable("unexpected response")))
            return
        }
        lock.lock()
        let body = buffer
        lock.unlock()
        finish(.success((http, body)))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // A 307 or 308 replays the POST body — the route corridor — at whatever host the
        // response names. Follow a redirect only back to the endpoint this app chose.
        let host = request.url?.host?.lowercased()
        let expected = SpeedLimitService.endpoint.host?.lowercased()
        let permitted = host != nil && host == expected && request.url?.scheme == "https"
        completionHandler(permitted ? request : nil)
    }
}
