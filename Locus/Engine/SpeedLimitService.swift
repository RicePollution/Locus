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
        /// Structurally not applicable: wrong travel mode, or the route is over the length cap.
        case notApplicable(reason: String)
        /// We tried and could not get it: offline, throttled, server error, nothing returned.
        case unavailable(reason: String)
    }

    // Tuning. Every one of these is a number an implementer would otherwise invent.
    static let endpoint = URL(string: "https://overpass-api.de/api/interpreter")!
    static let serverTimeout = 25              // the [timeout:N] inside the QL
    static let requestTimeout: TimeInterval = 30
    static let resourceTimeout: TimeInterval = 60
    static let maxResponseBytes = 8 * 1024 * 1024
    static let maxRouteLength: CLLocationDistance = 150_000
    static let decimationTolerance: CLLocationDistance = 8      // ε
    static let decimationLimit = 2_000
    static let queryRadius = 30                                 // R_q, metres
    static let retryDelays: [TimeInterval] = [2, 6]
    static let throttleCooldown: TimeInterval = 60
    static let cacheLimit = 8

    /// Overpass's usage policy asks for an identifying agent. `User-Agent` is not a reserved
    /// header on iOS and is sent as written.
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

    /// A dedicated session, not `.shared`. `httpMaximumConnectionsPerHost = 1` is what
    /// actually holds this app to one Overpass connection: actors are reentrant at every
    /// `await`, so actor isolation alone does not bound requests in flight.
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

    func profile(for route: RoadRoute, mode: TravelMode) async -> Outcome {
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
            tolerance: Self.decimationTolerance,
            limit: Self.decimationLimit
        )
        guard decimated.count >= 2 else {
            return .notApplicable(reason: "this route has no path to match")
        }

        let key = Self.cacheKey(for: decimated)
        if let hit = cache.first(where: { $0.key == key })?.profile {
            return .profile(hit)
        }
        if let cooldownUntil, cooldownUntil > Date() {
            return .unavailable(reason: "server busy")
        }

        let ways: [OSMWay]
        do {
            ways = try Self.decodeWays(try await send(Self.query(for: decimated)))
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
            unit: await inferUnit(from: ways, route: route.coordinates),
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

    // MARK: - Network

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
                    try await Task.sleep(nanoseconds: UInt64(min(retryAfter ?? 5, 15) * 1_000_000_000))
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

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            bytes.task.cancel()
            throw LookupFailure.unavailable("unexpected response")
        }
        switch http.statusCode {
        case 200:
            return try await Self.collect(bytes, limit: Self.maxResponseBytes)
        case 429:
            bytes.task.cancel()
            throw LookupFailure.throttled(
                retryAfter: http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            )
        case 500...599:
            // An overloaded dispatcher answers 504 with an HTML body, twice in seven
            // requests during the design probes. Worth retrying; nothing else here is.
            bytes.task.cancel()
            throw LookupFailure.serverBusy
        default:
            // A 4xx is our own query being wrong. Retrying our bug wastes a volunteer's
            // cycles, so log enough to fix it and give up.
            let body = await Self.head(bytes, limit: 500)
            Self.log.error("Overpass rejected the query (\(http.statusCode, privacy: .public)): \(body, privacy: .public)")
            throw LookupFailure.rejected
        }
    }

    private static func collect(_ bytes: URLSession.AsyncBytes, limit: Int) async throws -> Data {
        var buffer = Data()
        buffer.reserveCapacity(64 * 1024)
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count > limit {
                // Cancelled mid-stream on purpose: checking the size once the bytes are
                // already resident is exactly the memory spike the cap exists to prevent.
                bytes.task.cancel()
                throw LookupFailure.unavailable("response too large")
            }
        }
        return buffer
    }

    /// First `limit` bytes of an error body, for the log. Read failures are swallowed
    /// because the body is diagnostic only — the status code already named the failure.
    private static func head(_ bytes: URLSession.AsyncBytes, limit: Int) async -> String {
        var buffer = Data()
        do {
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= limit { break }
            }
        } catch {
            // Nothing to report: a truncated body is still a usable diagnostic.
        }
        bytes.task.cancel()
        return String(decoding: buffer, as: UTF8.self)
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

    /// `around` with a coordinate list is a corridor around the *chord* between the points,
    /// not around the road, which is why the polyline handed in must be Douglas–Peucker
    /// decimated rather than uniformly sampled.
    private static func query(for coordinates: [CLLocationCoordinate2D]) -> String {
        var body = "[out:json][timeout:\(serverTimeout)][maxsize:67108864];\n"
        body += "way[\"highway\"~\"^(motorway|trunk|primary|secondary|tertiary|unclassified"
        body += "|residential|living_street|service|motorway_link|trunk_link|primary_link"
        body += "|secondary_link|tertiary_link)$\"]\n"
        body += "  [\"service\"!~\"^(parking_aisle|driveway|drive-through|emergency_access)$\"]\n"
        body += "  [\"area\"!=\"yes\"]\n"
        body += "  (around:\(queryRadius)"
        for coordinate in coordinates {
            // %.5f is ~1.1 m. Finer is wasted bytes and leaks nothing useful.
            body += String(format: ",%.5f,%.5f", coordinate.latitude, coordinate.longitude)
        }
        body += ");\nout tags geom;"
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
    private func inferUnit(from ways: [OSMWay], route: [CLLocationCoordinate2D]) async -> SpeedUnit {
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
        if let code = await Self.geocodedCountryCode(at: route[route.count / 2]) {
            return SpeedUnit.forCountryCode(code)
        }
        return .kilometresPerHour
    }

    private static func geocodedCountryCode(at coordinate: CLLocationCoordinate2D) async -> String? {
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

    private static func cacheKey(for coordinates: [CLLocationCoordinate2D]) -> Int {
        var hasher = Hasher()
        hasher.combine(queryRadius)
        for coordinate in coordinates {
            hasher.combine(Int((coordinate.latitude * 100_000).rounded()))
            hasher.combine(Int((coordinate.longitude * 100_000).rounded()))
        }
        return hasher.finalize()
    }
}
