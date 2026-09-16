import CoreLocation
import Foundation

/// Matches a route polyline against the OSM ways around it and folds the result into a
/// `SpeedProfile`. Pure and synchronous; the actor that calls it owns the off-main-actor
/// guarantee.
enum SpeedLimitMatcher {
    /// Perpendicular distance at which a way is close enough to be the road we are on.
    static let matchRadius: CLLocationDistance = 20
    /// Grid cell side. Exactly `2 * matchRadius`, which is what makes a 3×3 neighbourhood
    /// provably contain every segment within `matchRadius` of a point in the centre cell.
    static let cellSize: CLLocationDistance = 40
    /// Longest way segment carried into the grid. Anything longer is subdivided so that
    /// insertion cost stays O(few cells) with no special case for a 2 km rural straight.
    static let maxSegmentLength: CLLocationDistance = 60
    /// OSM way direction is arbitrary on two-way roads, so the comparison is undirected and
    /// this is a folded difference. Without it every point near a crossroads matches the
    /// cross street, and the mode filter cannot repair that — the errors cluster at
    /// junctions rather than arriving isolated.
    static let maxBearingDifference: Double = 40
    /// Score bonus for the way that matched the previous point. Kills flapping between the
    /// two carriageways of a divided highway and between a road and its service road.
    static let hysteresisBonus: CLLocationDistance = 6
    /// Odd window for the mode filter over matched way ids.
    static let smoothingWindow = 5
    /// Ceiling on subdivided segments. A single malformed way with a continent-spanning
    /// segment would otherwise subdivide into millions of pieces before anything noticed.
    static let maxSegments = 400_000

    /// Douglas–Peucker. Keeps the corridor on the road: the algorithm's own error metric is
    /// perpendicular deviation, which is precisely what Overpass's `around` measures.
    ///
    /// Over-budget results widen the tolerance rather than truncating the list. Cutting the
    /// tail off is the one thing that must not happen here — the query would then cover
    /// everything but the end of the route.
    static func decimate(
        _ coordinates: [CLLocationCoordinate2D],
        tolerance: CLLocationDistance,
        limit: Int
    ) -> [CLLocationCoordinate2D] {
        guard coordinates.count > 2, limit >= 2 else { return coordinates }
        let projection = Projection(origin: coordinates[0])
        let xs = coordinates.map { projection.x($0.longitude) }
        let ys = coordinates.map { projection.y($0.latitude) }

        var currentTolerance = max(tolerance, 0.5)
        var kept = simplify(xs: xs, ys: ys, tolerance: currentTolerance)
        while kept.count > limit, currentTolerance < 200_000 {
            currentTolerance *= 2
            kept = simplify(xs: xs, ys: ys, tolerance: currentTolerance)
        }
        return kept.map { coordinates[$0] }
    }

    static func profile(
        route: [CLLocationCoordinate2D],
        ways: [OSMWay],
        unit: SpeedUnit,
        fallback: CLLocationSpeed,
        fallbackSource: SpeedSource
    ) -> SpeedProfile {
        guard route.count >= 2 else {
            return SpeedProfile(
                rawZones: [],
                routeLength: 0,
                unit: unit,
                fallback: fallback,
                fallbackSource: fallbackSource
            )
        }

        // Arc length along the route in the same metric the pacer walks it with, so a zone
        // boundary lands where the follower thinks it is. Everything else in this file is
        // projected metres; this one is not, because it crosses into the pacer.
        var cumulative = [CLLocationDistance](repeating: 0, count: route.count)
        for index in 1..<route.count {
            let previous = CLLocation(latitude: route[index - 1].latitude, longitude: route[index - 1].longitude)
            let current = CLLocation(latitude: route[index].latitude, longitude: route[index].longitude)
            cumulative[index] = cumulative[index - 1] + previous.distance(from: current)
        }
        let routeLength = cumulative[route.count - 1]

        let projection = Projection(origin: route[0])
        let rx = route.map { projection.x($0.longitude) }
        let ry = route.map { projection.y($0.latitude) }

        let segments = Segments(ways: ways, projection: projection)
        let matched = smoothed(
            match(rx: rx, ry: ry, segments: segments),
            window: smoothingWindow
        )

        let fallbackResolution = Resolution(
            speed: SpeedProfile.clamp(fallback),
            source: fallbackSource,
            roadName: ""
        )
        let resolved = ways.map { resolve($0, unit: unit, fallback: fallbackResolution) }

        var zones: [SpeedProfile.Zone] = []
        var lastQuantised: Int?
        for index in 0..<route.count {
            let wayIndex = matched[index]
            let speed = wayIndex >= 0 ? resolved[Int(wayIndex)] : fallbackResolution
            let quantised = Int((speed.speed * 10).rounded())
            guard quantised != lastQuantised else { continue }
            lastQuantised = quantised
            zones.append(SpeedProfile.Zone(
                start: cumulative[index],
                speed: speed.speed,
                source: speed.source,
                roadName: speed.roadName
            ))
        }

        return SpeedProfile(
            rawZones: zones,
            routeLength: routeLength,
            unit: unit,
            fallback: fallback,
            fallbackSource: fallbackSource
        )
    }

    // MARK: - Resolution

    private struct Resolution {
        let speed: CLLocationSpeed
        let source: SpeedSource
        let roadName: String
    }

    private static func resolve(_ way: OSMWay, unit: SpeedUnit, fallback: Resolution) -> Resolution {
        let name = way.tags["name"] ?? way.tags["ref"] ?? ""
        let maxspeed = MaxspeedParser.parse(way.tags["maxspeed"] ?? "")
        if let speed = maxspeed.speed {
            return Resolution(speed: SpeedProfile.clamp(speed), source: .posted, roadName: name)
        }
        let implied = maxspeed.classHint
            ?? MaxspeedParser.parse(way.tags["maxspeed:type"] ?? "").classHint
            ?? MaxspeedParser.parse(way.tags["source:maxspeed"] ?? "").classHint
        let highway = HighwayClass.parse(way.tags["highway"] ?? "")
        // The zone keyword can override the class, but "is this a slip road" is a fact
        // about the `highway=` tag and nothing an implicit value says can change it.
        guard let roadClass = implied?.class ?? highway?.class else { return fallback }
        let speed = roadClass.defaultSpeed(unit: unit, isLink: highway?.isLink ?? false)
        return Resolution(speed: SpeedProfile.clamp(speed), source: .impliedByClass, roadName: name)
    }

    // MARK: - Matching

    private static func match(rx: [Double], ry: [Double], segments: Segments) -> [Int32] {
        var matched = [Int32](repeating: -1, count: rx.count)
        guard !segments.isEmpty else { return matched }
        let radiusSquared = matchRadius * matchRadius
        var previousWay: Int32 = -1

        for index in 0..<rx.count {
            let px = rx[index]
            let py = ry[index]
            let bearing = routeBearing(rx: rx, ry: ry, at: index)
            let cx = Int(floor(px / cellSize))
            let cy = Int(floor(py / cellSize))
            var bestScore = Double.greatestFiniteMagnitude
            var best: Int32 = -1

            for dx in -1...1 {
                for dy in -1...1 {
                    guard let bucket = segments.grid[Segments.cellKey(cx + dx, cy + dy)] else { continue }
                    for packed in bucket {
                        let segment = Int(packed)
                        let distanceSquared = pointSegmentDistanceSquared(
                            px: px, py: py,
                            ax: segments.x0[segment], ay: segments.y0[segment],
                            bx: segments.x1[segment], by: segments.y1[segment]
                        )
                        guard distanceSquared <= radiusSquared else { continue }
                        let segmentBearing = bearingDegrees(
                            dx: segments.x1[segment] - segments.x0[segment],
                            dy: segments.y1[segment] - segments.y0[segment]
                        )
                        guard foldedBearingDifference(bearing, segmentBearing) <= maxBearingDifference else { continue }
                        // sqrt only for candidates that already passed both gates: the
                        // hysteresis bonus is in metres and cannot be applied to a square.
                        var score = distanceSquared.squareRoot()
                        if segments.way[segment] == previousWay { score -= hysteresisBonus }
                        if score < bestScore {
                            bestScore = score
                            best = segments.way[segment]
                        }
                    }
                }
            }

            matched[index] = best
            if best >= 0 { previousWay = best }
        }
        return matched
    }

    /// Mode filter over matched way ids. Replaces isolated flips and fills single unmatched
    /// points from their neighbours; a run of unmatched points stays unmatched, which is a
    /// legal state the fallback chain already covers.
    private static func smoothed(_ ids: [Int32], window: Int) -> [Int32] {
        guard ids.count > window, window > 1 else { return ids }
        let half = window / 2
        var output = ids
        var counts: [Int32: Int] = [:]
        counts.reserveCapacity(window)
        for index in 0..<ids.count {
            counts.removeAll(keepingCapacity: true)
            let lower = max(0, index - half)
            let upper = min(ids.count - 1, index + half)
            for neighbour in lower...upper {
                counts[ids[neighbour], default: 0] += 1
            }
            var bestID = ids[index]
            var bestCount = counts[bestID] ?? 0
            for (id, count) in counts where count > bestCount {
                bestID = id
                bestCount = count
            }
            output[index] = bestID
        }
        return output
    }

    /// Bearing through point `index` by central difference, one-sided at the ends.
    ///
    /// The window widens past a degenerate difference: duplicate track points are emitted by
    /// every GPS recorder while a device sits still, and `atan2(0, 0)` is a meaningless 0°
    /// that the bearing gate would then enforce against every candidate.
    private static func routeBearing(rx: [Double], ry: [Double], at index: Int) -> Double {
        var lower = max(0, index - 1)
        var upper = min(rx.count - 1, index + 1)
        var widened = 0
        while hypot(rx[upper] - rx[lower], ry[upper] - ry[lower]) < 1,
              widened < 8,
              lower > 0 || upper < rx.count - 1 {
            if lower > 0 { lower -= 1 }
            if upper < rx.count - 1 { upper += 1 }
            widened += 1
        }
        return bearingDegrees(dx: rx[upper] - rx[lower], dy: ry[upper] - ry[lower])
    }

    // MARK: - Geometry

    /// Equirectangular projection into local metres, origin at the route's first coordinate.
    /// Over 150 km of latitude the x-scale error reaches ~1.3%, which on a 20 m threshold is
    /// 0.26 m — and it applies identically to the route and to the ways.
    private struct Projection {
        let lat0: Double
        let lon0: Double
        let xScale: Double

        init(origin: CLLocationCoordinate2D) {
            lat0 = origin.latitude
            lon0 = origin.longitude
            xScale = cos(origin.latitude * .pi / 180) * 111_320
        }

        func x(_ longitude: Double) -> Double { (longitude - lon0) * xScale }
        func y(_ latitude: Double) -> Double { (latitude - lat0) * 110_540 }
    }

    /// Way segments in flat parallel arrays with a uniform hash grid over them. Flat arrays
    /// rather than structs because this is the only part of the feature where the constant
    /// factor shows: a long urban route is a few million squared-distance evaluations.
    private struct Segments {
        var x0: [Double] = []
        var y0: [Double] = []
        var x1: [Double] = []
        var y1: [Double] = []
        var way: [Int32] = []
        var grid: [Int64: [Int32]] = [:]

        var isEmpty: Bool { way.isEmpty }

        init(ways: [OSMWay], projection: Projection) {
            outer: for (wayIndex, osmWay) in ways.enumerated() {
                guard osmWay.geometry.count >= 2 else { continue }
                for (a, b) in zip(osmWay.geometry, osmWay.geometry.dropFirst()) {
                    let ax = projection.x(a.longitude)
                    let ay = projection.y(a.latitude)
                    let bx = projection.x(b.longitude)
                    let by = projection.y(b.latitude)
                    let length = hypot(bx - ax, by - ay)
                    guard length.isFinite else { continue }
                    let pieces = max(1, Int((length / maxSegmentLength).rounded(.up)))
                    for piece in 0..<pieces {
                        guard way.count < maxSegments else { break outer }
                        let t0 = Double(piece) / Double(pieces)
                        let t1 = Double(piece + 1) / Double(pieces)
                        append(
                            x0: ax + (bx - ax) * t0, y0: ay + (by - ay) * t0,
                            x1: ax + (bx - ax) * t1, y1: ay + (by - ay) * t1,
                            way: Int32(wayIndex)
                        )
                    }
                }
            }
        }

        private mutating func append(x0 ax: Double, y0 ay: Double, x1 bx: Double, y1 by: Double, way wayIndex: Int32) {
            let index = Int32(way.count)
            x0.append(ax)
            y0.append(ay)
            x1.append(bx)
            y1.append(by)
            way.append(wayIndex)
            // Inflating the bounding box by the match radius is what lets the per-point scan
            // read only the 3×3 neighbourhood and still see everything within the radius.
            let minX = min(ax, bx) - matchRadius
            let maxX = max(ax, bx) + matchRadius
            let minY = min(ay, by) - matchRadius
            let maxY = max(ay, by) + matchRadius
            let cx0 = Int(floor(minX / cellSize))
            let cx1 = Int(floor(maxX / cellSize))
            let cy0 = Int(floor(minY / cellSize))
            let cy1 = Int(floor(maxY / cellSize))
            guard cx1 >= cx0, cy1 >= cy0 else { return }
            for cx in cx0...cx1 {
                for cy in cy0...cy1 {
                    grid[Segments.cellKey(cx, cy), default: []].append(index)
                }
            }
        }

        static func cellKey(_ cx: Int, _ cy: Int) -> Int64 {
            (Int64(Int32(truncatingIfNeeded: cx)) << 32) | Int64(UInt32(bitPattern: Int32(truncatingIfNeeded: cy)))
        }
    }

    private static func simplify(xs: [Double], ys: [Double], tolerance: Double) -> [Int] {
        let count = xs.count
        var keep = [Bool](repeating: false, count: count)
        keep[0] = true
        keep[count - 1] = true
        let toleranceSquared = tolerance * tolerance
        // Explicit stack, not recursion: a 20,000-point polyline can recurse that deep.
        var stack: [(Int, Int)] = [(0, count - 1)]
        while let (first, last) = stack.popLast() {
            guard last > first + 1 else { continue }
            var worst = 0.0
            var worstIndex = first
            for index in (first + 1)..<last {
                let distanceSquared = pointSegmentDistanceSquared(
                    px: xs[index], py: ys[index],
                    ax: xs[first], ay: ys[first],
                    bx: xs[last], by: ys[last]
                )
                if distanceSquared > worst {
                    worst = distanceSquared
                    worstIndex = index
                }
            }
            guard worst > toleranceSquared else { continue }
            keep[worstIndex] = true
            stack.append((first, worstIndex))
            stack.append((worstIndex, last))
        }
        return (0..<count).filter { keep[$0] }
    }

    private static func pointSegmentDistanceSquared(
        px: Double, py: Double,
        ax: Double, ay: Double,
        bx: Double, by: Double
    ) -> Double {
        let vx = bx - ax
        let vy = by - ay
        let lengthSquared = vx * vx + vy * vy
        var t = 0.0
        if lengthSquared > 0 {
            t = ((px - ax) * vx + (py - ay) * vy) / lengthSquared
            t = min(1, max(0, t))
        }
        let dx = px - (ax + vx * t)
        let dy = py - (ay + vy * t)
        return dx * dx + dy * dy
    }

    /// Compass bearing in degrees for an east/north displacement in the projected plane.
    private static func bearingDegrees(dx: Double, dy: Double) -> Double {
        let degrees = atan2(dx, dy) * 180 / .pi
        return degrees < 0 ? degrees + 360 : degrees
    }

    /// Undirected angle between two bearings, folded into `[0°, 90°]`.
    private static func foldedBearingDifference(_ a: Double, _ b: Double) -> Double {
        let difference = abs(a - b).truncatingRemainder(dividingBy: 180)
        return difference > 90 ? 180 - difference : difference
    }
}
