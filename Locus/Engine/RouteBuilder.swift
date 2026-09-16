import CoreLocation
import Foundation
import MapKit

/// One routing answer from MapKit, ready to draw and to follow.
///
/// `distance` and `expectedTravelTime` are Apple's own numbers for the route, not
/// anything derived from the sampled coordinates: they are what Apple Maps would quote,
/// and they stay meaningful even after sampling has coarsened the geometry.
struct RoadRoute: Identifiable {
    let id = UUID()
    /// MapKit's label for the route — "I-90 W", "Broadway". Empty for short hops.
    var name: String
    /// Densified copy of the route polyline; this is the path the follower walks.
    var coordinates: [CLLocationCoordinate2D]
    var distance: CLLocationDistance
    var expectedTravelTime: TimeInterval
    /// The spacing the geometry was actually sampled at, when that is coarser than the
    /// ideal — nil when the route is carried at full fidelity. A long route is thinned
    /// to fit the point budget, which is a fair trade against the alternative of losing
    /// its tail, but the user picked a specific route out of a ranked list and the path
    /// they will follow is no longer exactly the one they picked. Worth one line.
    var simplifiedSpacing: CLLocationDistance?
    /// True when source vertices were actually discarded to fit the budget, as opposed to
    /// merely interpolated more coarsely. Only this one means the *shape* changed:
    /// widening the step drops no vertex, because every leg's final interpolated point
    /// lands exactly on the source point.
    var droppedVertices: Bool
    /// Set when footpath directions were not used and road directions were followed
    /// instead. Nil means the route is what was asked for.
    var fallback: RouteFallback?

    /// Average speed Apple's routing engine implies for this route. It already accounts
    /// for limits, junctions, and — for automobile routes with a departure date —
    /// traffic, which makes it a good sanity bound on any speed we pick ourselves.
    ///
    /// Optional rather than a zero sentinel: a speed of zero is not a slow route, it is
    /// the absence of an answer, and anything that divided by the sentinel would get
    /// infinity and then trap on the `Int(ceil(…))` conversion downstream.
    var averageSpeed: CLLocationSpeed? {
        guard expectedTravelTime > 0, distance > 0 else { return nil }
        return distance / expectedTravelTime
    }
}

/// Why a walking request ended up following roads.
///
/// The distinction is the whole point of the type. One of these is a fact about the
/// world and the other is a fact about the network, and the retry that produces them is
/// deliberately *not* gated on which — so telling someone "no footpath route available"
/// when the truth is "I couldn't reach Apple just then" asserts something the code never
/// established, and leaves them with no reason to try again.
enum RouteFallback {
    /// MapKit answered, and said there is no walking route between these two points.
    case noWalkingRoute
    /// The walking request never got an answer — offline, throttled, or timed out.
    case walkingLookupUnverified

    var explanation: String {
        switch self {
        case .noWalkingRoute:
            return "following roads (no footpath route available)"
        case .walkingLookupUnverified:
            return "following roads (couldn't check footpaths just now — rebuild to retry)"
        }
    }
}

enum RouteError: LocalizedError {
    case endpointsTooClose
    case noRoute(TravelMode)
    case lookupFailed(TravelMode, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .endpointsTooClose:
            return "Start and end are the same place. Drop a pin somewhere else and set it "
                + "as the end, or move the start."
        case .lookupFailed(let mode, let underlying):
            return "Couldn't fetch \(mode.title.lowercased()) directions: \(underlying.localizedDescription)"
        case .noRoute(let mode):
            return "Apple Maps has no \(mode.title.lowercased()) route between those two points. "
                + "They may be too far apart, or separated by water. Try an end point closer to "
                + "the start, switch travel mode, or draw a path on the map instead."
        }
    }
}

/// Thrown by `directions` when MapKit answers with an empty route list.
private struct NoRoutesFound: Error {}

enum RouteBuilder {
    /// Below this the two endpoints are the same place as far as routing goes. MapKit
    /// answers such a request with a bare "directions not available", which reads as
    /// "your destination is unreachable" — the planner's start defaults to the current
    /// position, so a user who only sets an end lands here constantly and deserves to be
    /// told what actually happened.
    static let minimumRouteDistance: CLLocationDistance = 15

    /// Spacing a route is densified at when it comfortably fits the point budget.
    static let idealSpacing: CLLocationDistance = 12

    /// Every route MapKit is willing to offer for these endpoints, quickest first.
    ///
    /// Asking for alternates and sorting them ourselves is the whole point: MapKit puts
    /// its own preferred route at the head of the list, but that preference is not
    /// strictly by time, so `routes.first` was not the route Apple Maps would actually
    /// suggest. The caller gets the full set so the planner can show the same choice
    /// Apple Maps and Google Maps show.
    static func roadRoutes(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D,
        mode: TravelMode
    ) async throws -> [RoadRoute] {
        let separation = CLLocation(latitude: start.latitude, longitude: start.longitude)
            .distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))
        guard separation >= minimumRouteDistance else { throw RouteError.endpointsTooClose }

        let primaryError: Error
        do {
            return try await directions(
                from: start, to: end,
                transportType: mode.mkTransportType,
                fallback: nil
            )
        } catch {
            primaryError = error
        }

        // MapKit refuses walking directions beyond a short distance, which is the usual
        // cause of "directions not available" after teleporting somewhere far. The road
        // retry is one cheap extra request that can only help, so it is NEVER gated on
        // how the first attempt failed — a throttled or offline first attempt often
        // succeeds on the second. Classification decides the message, not the retry.
        guard mode.mkTransportType == .walking else {
            throw routeError(for: mode, attempts: [primaryError])
        }
        do {
            // Classify the walking failure for the *message* only. The retry above ran
            // regardless, which is the correct behaviour; this just stops the result
            // claiming footpaths were checked when they were not.
            return try await directions(
                from: start, to: end,
                transportType: .automobile,
                fallback: routeGenuinelyUnavailable(primaryError)
                    ? .noWalkingRoute
                    : .walkingLookupUnverified
            )
        } catch {
            throw routeError(for: mode, attempts: [primaryError, error])
        }
    }

    /// Only claim the two points are unroutable when *every* attempt actually said so.
    /// If any of them failed because MapKit could not go and look, report that instead —
    /// telling an offline user their destination is unreachable is the misleading answer.
    private static func routeError(for mode: TravelMode, attempts: [Error]) -> RouteError {
        if let lookupFailure = attempts.first(where: { !routeGenuinelyUnavailable($0) }) {
            return .lookupFailed(mode, underlying: lookupFailure)
        }
        return .noRoute(mode)
    }

    /// True only when MapKit is saying "there is no such route", as opposed to "I could
    /// not go and look". Anything unrecognised is treated as a lookup failure, since
    /// claiming two points are unreachable is the more misleading of the two answers.
    private static func routeGenuinelyUnavailable(_ error: Error) -> Bool {
        if error is NoRoutesFound { return true }
        guard let mkError = error as? MKError else { return false }
        switch mkError.code {
        case .directionsNotFound, .placemarkNotFound:
            return true
        default:
            return false
        }
    }

    private static func directions(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D,
        transportType: MKDirectionsTransportType,
        fallback: RouteFallback?
    ) async throws -> [RoadRoute] {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: start))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: end))
        request.transportType = transportType
        request.requestsAlternateRoutes = true
        // Automobile ETAs are traffic-aware only when a departure date is supplied, and
        // the ETA is what the routes are ranked by — without this they are all quoted at
        // free-flow speed and the ranking is the wrong one at rush hour. Scoped to the
        // transport type the justification actually covers: walking ETAs do not vary
        // with traffic, and upstream sent no departure date at all.
        if transportType == .automobile {
            request.departureDate = Date()
        }

        let response = try await MKDirections(request: request).calculate()
        guard !response.routes.isEmpty else { throw NoRoutesFound() }
        return response.routes
            // Distance breaks ties so the order is deterministic; Swift's sort is not
            // stable, and two equal-time alternates reshuffling between builds would
            // silently swap which route the planner has highlighted.
            .sorted {
                // A non-positive ETA is a missing answer, not a zero-second journey, so
                // it must not sort to the head and get labelled "Fastest" — it would be
                // auto-selected and rendered as "< 1 min" for a 12-mile drive.
                (Self.rank($0.expectedTravelTime), $0.distance)
                    < (Self.rank($1.expectedTravelTime), $1.distance)
            }
            .map { route in
                let step = spacing(forRouteLength: route.distance)
                // Thinning is the more destructive half: past the source cap, dropped
                // vertices cut across tight interchange loops rather than merely
                // smoothing them.
                let wasThinned = route.polyline.pointCount > maxSourcePoints
                return RoadRoute(
                    name: route.name,
                    coordinates: sample(polyline: route.polyline, every: step),
                    distance: route.distance,
                    expectedTravelTime: route.expectedTravelTime,
                    simplifiedSpacing: (step > idealSpacing || wasThinned) ? step : nil,
                    droppedVertices: wasThinned,
                    fallback: fallback
                )
            }
    }

    /// Sort key that pushes unusable ETAs to the back instead of the front.
    private static func rank(_ travelTime: TimeInterval) -> TimeInterval {
        travelTime > 0 && travelTime.isFinite ? travelTime : .greatestFiniteMagnitude
    }

    /// Spacing to densify a route of this length at, in meters.
    ///
    /// `sample` stops dead once it has produced `maxSampledPoints`, so the old fixed 12 m
    /// step silently discarded everything past roughly 240 km: a long drive drew and
    /// followed to a point in the middle of nowhere and simply ended, with nothing in the
    /// UI to say so. Widening the step for long routes trades a little fidelity — which
    /// only matters at junction scale, and long routes are mostly not junctions — for a
    /// route that actually reaches its destination.
    static func spacing(
        forRouteLength meters: CLLocationDistance,
        ideal: CLLocationDistance = idealSpacing
    ) -> CLLocationDistance {
        guard meters.isFinite, meters > 0 else { return ideal }
        // Only part of the ceiling is spent on interpolation: every leg costs at least
        // one point whatever the spacing, and `maxSourcePoints` of those are already
        // committed before a single point is interpolated. The two together have to stay
        // under `maxSampledPoints`, or the hard break amputates the tail again.
        // Clamped: if `maxSourcePoints` were ever raised to meet or exceed
        // `maxSampledPoints`, an unclamped budget would go zero or negative, `max(ideal,
        // …)` would collapse back to `ideal`, and the break in `sample` would start
        // amputating tails again — the exact bug this whole path exists to prevent, back
        // with the same absence of any signal. The two constants are bound together.
        let budget = Double(max(1, maxSampledPoints - maxSourcePoints)) * 0.95
        return max(ideal, meters / budget)
    }

    static func sample(polyline: MKPolyline, every meters: CLLocationDistance) -> [CLLocationCoordinate2D] {
        var coords = [CLLocationCoordinate2D](repeating: .init(), count: polyline.pointCount)
        polyline.getCoordinates(&coords, range: NSRange(location: 0, length: polyline.pointCount))
        return sample(coordinates: coords, every: meters)
    }

    /// Ceiling on interpolated points. A GPX with a huge jump between two consecutive
    /// track points — a flight leg, a corrupt file — would otherwise interpolate millions
    /// of coordinates on the main actor and hang or kill the app.
    static let maxSampledPoints = 20_000
    /// Most source points carried into the sampler. Past this the input is thinned, not
    /// truncated: a 300 km route polyline can arrive with more vertices than the whole
    /// ceiling allows, and densifying it was never going to fit whatever the spacing.
    private static let maxSourcePoints = 5_000
    /// Most interpolated points allowed for a single pair, so one bad leg cannot consume
    /// the whole budget and leave the rest of the track unsampled.
    private static let maxStepsPerLeg = 2_000

    static func sample(coordinates: [CLLocationCoordinate2D], every meters: CLLocationDistance) -> [CLLocationCoordinate2D] {
        guard coordinates.count > 1 else { return coordinates }
        let source = thinned(coordinates, to: maxSourcePoints)
        // Widen the step if the requested one would not fit. Both guards exist because
        // the loop below stops dead at the ceiling, and stopping dead means the end of
        // the route is gone — the follower walks to somewhere in the middle and halts,
        // which is indistinguishable from the route having been built wrong.
        let step = spacing(forRouteLength: length(of: source), ideal: meters)
        var sampled = [source[0]]
        for (a, b) in zip(source, source.dropFirst()) {
            if sampled.count >= maxSampledPoints { break }
            let dist = CLLocation(latitude: a.latitude, longitude: a.longitude)
                .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
            let steps = min(maxStepsPerLeg, max(1, Int(ceil(dist / step))))
            for i in 1...steps {
                let t = Double(i) / Double(steps)
                sampled.append(CLLocationCoordinate2D(
                    latitude: a.latitude + (b.latitude - a.latitude) * t,
                    longitude: a.longitude + (b.longitude - a.longitude) * t
                ))
            }
        }
        return sampled
    }

    /// Keep exactly `limit` points, evenly spread, including both endpoints. Thinning
    /// preserves the track's full extent; the old ceiling stopped copying partway
    /// instead, which amputated the end of it.
    ///
    /// The output index is mapped back onto the input rather than walking an integer
    /// stride. A stride of 2 over 5,001 points keeps 2,501 of the 5,000 allowed and
    /// throws away half the permitted fidelity for one point of overshoot, with the same
    /// cliff at every multiple of the limit.
    private static func thinned(_ coordinates: [CLLocationCoordinate2D], to limit: Int) -> [CLLocationCoordinate2D] {
        guard limit > 1, coordinates.count > limit else { return coordinates }
        let lastIndex = coordinates.count - 1
        var kept: [CLLocationCoordinate2D] = []
        kept.reserveCapacity(limit)
        for i in 0..<limit {
            let position = Double(i) * Double(lastIndex) / Double(limit - 1)
            kept.append(coordinates[min(Int(position.rounded()), lastIndex)])
        }
        return kept
    }

    private static func length(of coordinates: [CLLocationCoordinate2D]) -> CLLocationDistance {
        zip(coordinates, coordinates.dropFirst()).reduce(0) { total, pair in
            total + CLLocation(latitude: pair.0.latitude, longitude: pair.0.longitude)
                .distance(from: CLLocation(latitude: pair.1.latitude, longitude: pair.1.longitude))
        }
    }
}

/// Locale-correct rendering of the numbers a route quotes. Lives beside the route
/// rather than on the planner sheet: the map's status line needs the same strings, and
/// a View type is the wrong place for a map layer to reach into.
enum RouteFormat {
    /// MKDistanceFormatter follows the device's measurement system, so a US user reads
    /// miles and everyone else reads kilometres without us deciding for them.
    private static let distanceFormatter: MKDistanceFormatter = {
        let f = MKDistanceFormatter()
        f.unitStyle = .abbreviated
        return f
    }()

    private static let durationFormatter: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.allowedUnits = [.hour, .minute]
        f.unitsStyle = .abbreviated
        f.maximumUnitCount = 2
        return f
    }()

    /// "12 km · 15 min", or just the distance when MapKit quoted no usable ETA.
    static func summary(for route: RoadRoute) -> String {
        guard let duration = duration(route.expectedTravelTime) else {
            return "\(distance(route.distance)) · no ETA"
        }
        return "\(distance(route.distance)) · \(duration)"
    }

    static func distance(_ meters: CLLocationDistance) -> String {
        distanceFormatter.string(fromDistance: meters)
    }

    /// Nil when MapKit gave no usable estimate, so callers render the absence rather
    /// than printing a confident "< 1 min" for a journey of unknown length.
    static func duration(_ seconds: TimeInterval) -> String? {
        guard seconds > 0, seconds.isFinite else { return nil }
        // Anything under a minute formats as an empty string with .hour/.minute units,
        // which would render as a bare separator dot.
        guard seconds >= 60 else { return "< 1 min" }
        return durationFormatter.string(from: seconds)
    }
}

enum GPXCodec {
    static func parse(_ url: URL) throws -> [CLLocationCoordinate2D] {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        let text = String(decoding: data, as: UTF8.self)
        var coords: [CLLocationCoordinate2D] = []
        let pattern = #"lat="([^"]+)"[^>]*lon="([^"]+)""#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        regex.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match,
                  let latR = Range(match.range(at: 1), in: text),
                  let lonR = Range(match.range(at: 2), in: text),
                  let lat = Double(text[latR]),
                  let lon = Double(text[lonR]) else { return }
            coords.append(CLLocationCoordinate2D(latitude: lat, longitude: lon))
        }
        // Also support lon before lat
        if coords.isEmpty {
            let alt = #"lon="([^"]+)"[^>]*lat="([^"]+)""#
            let altRegex = try NSRegularExpression(pattern: alt)
            altRegex.enumerateMatches(in: text, range: range) { match, _, _ in
                guard let match,
                      let lonR = Range(match.range(at: 1), in: text),
                      let latR = Range(match.range(at: 2), in: text),
                      let lon = Double(text[lonR]),
                      let lat = Double(text[latR]) else { return }
                coords.append(CLLocationCoordinate2D(latitude: lat, longitude: lon))
            }
        }
        guard !coords.isEmpty else {
            throw NSError(domain: "Locus", code: 2, userInfo: [NSLocalizedDescriptionKey: "No track points found in GPX"])
        }
        return coords
    }

    static func export(_ coordinates: [CLLocationCoordinate2D], name: String = "Locus Route") -> String {
        var body = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="Locus" xmlns="http://www.topografix.com/GPX/1/1">
          <trk>
            <name>\(name)</name>
            <trkseg>

        """
        for c in coordinates {
            body += String(format: "      <trkpt lat=\"%.6f\" lon=\"%.6f\"></trkpt>\n", c.latitude, c.longitude)
        }
        body += """
            </trkseg>
          </trk>
        </gpx>
        """
        return body
    }
}
