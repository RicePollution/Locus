import CoreLocation
import Foundation
import MapKit

/// Outcome of a road-route request.
struct RoadRoute {
    var coordinates: [CLLocationCoordinate2D]
    /// True when footpath directions were unavailable and road directions were used
    /// instead. Following still moves at the travel mode's own speed.
    var fellBackToRoads: Bool
}

enum RouteError: LocalizedError {
    case noRoute(TravelMode)
    case lookupFailed(TravelMode, underlying: Error)

    var errorDescription: String? {
        switch self {
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
    static func roadRoute(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D,
        mode: TravelMode
    ) async throws -> RoadRoute {
        let primaryError: Error
        do {
            let coords = try await directions(from: start, to: end, transportType: mode.mkTransportType)
            return RoadRoute(coordinates: coords, fellBackToRoads: false)
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
            let coords = try await directions(from: start, to: end, transportType: .automobile)
            return RoadRoute(coordinates: coords, fellBackToRoads: true)
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
        transportType: MKDirectionsTransportType
    ) async throws -> [CLLocationCoordinate2D] {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: start))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: end))
        request.transportType = transportType
        request.requestsAlternateRoutes = false

        let response = try await MKDirections(request: request).calculate()
        guard let route = response.routes.first else { throw NoRoutesFound() }
        return sample(polyline: route.polyline, every: 12)
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
    /// Most interpolated points allowed for a single pair, so one bad leg cannot consume
    /// the whole budget and leave the rest of the track unsampled.
    private static let maxStepsPerLeg = 2_000

    static func sample(coordinates: [CLLocationCoordinate2D], every meters: CLLocationDistance) -> [CLLocationCoordinate2D] {
        guard coordinates.count > 1 else { return coordinates }
        var sampled = [coordinates[0]]
        for (a, b) in zip(coordinates, coordinates.dropFirst()) {
            if sampled.count >= maxSampledPoints { break }
            let dist = CLLocation(latitude: a.latitude, longitude: a.longitude)
                .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
            let steps = min(maxStepsPerLeg, max(1, Int(ceil(dist / meters))))
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
