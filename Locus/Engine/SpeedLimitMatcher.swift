import CoreLocation
import Foundation

/// Matches a route polyline against the OSM ways around it and folds the result into a
/// `SpeedProfile`. Pure, synchronous and deterministic; the actor that calls it owns the
/// off-main-actor guarantee.
enum SpeedLimitMatcher {
    /// Perpendicular distance at which a way is close enough to be the road we are on.
    static let matchRadius: CLLocationDistance = 20
    /// Douglas–Peucker tolerance the query polyline is decimated at, and the point budget it
    /// has to fit. They live beside `matchRadius` rather than in the service because
    /// `queryRadius(forTolerance:)` binds all three together, and someone tuning one number
    /// has to be looking at the other two.
    static let decimationTolerance: CLLocationDistance = 8
    static let decimationLimit = 2_000
    /// Grid cell side. A pure space/time tradeoff and nothing more: `Segments.append`
    /// inflates each segment's bounding box by `matchRadius` before inserting it, so every
    /// segment within `matchRadius` of a point is already registered in that point's own
    /// cell and the per-point scan reads one cell rather than a 3×3 neighbourhood.
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
    /// Furthest a projected point may sit from the route origin before the grid stops
    /// considering it. Half the planet, so no real coordinate reaches it — it exists because
    /// `Int(floor(x / cellSize))` traps on anything outside `Int`'s range, and a route
    /// coordinate has never been range-checked the way a decoded way's has.
    static let maxProjectedMagnitude: Double = 40_000_000

    /// Metres from `point` to the segment `a`–`b`.
    ///
    /// Exposed because the Overpass corridor is drawn around the *segments* between the
    /// coordinates it is given, not around the coordinates themselves — so anything deciding
    /// what the corridor may cover has to measure the same thing the corridor does.
    static func distance(
        from point: CLLocationCoordinate2D,
        toSegment a: CLLocationCoordinate2D,
        _ b: CLLocationCoordinate2D
    ) -> CLLocationDistance {
        // Origin at the point, where the projection is most accurate and where the threshold
        // that uses this actually matters.
        let projection = Projection(origin: point)
        return pointSegmentDistanceSquared(
            px: 0, py: 0,
            ax: projection.x(a.longitude), ay: projection.y(a.latitude),
            bx: projection.x(b.longitude), by: projection.y(b.latitude)
        ).squareRoot()
    }

    /// Corridor radius the Overpass query must use for a polyline decimated at `tolerance`.
    ///
    /// The query is built from the *decimated* polyline while the matcher works on the full
    /// one, and a full-polyline point can sit up to `tolerance` from the decimated line. A
    /// way within `matchRadius` of a route point is therefore only guaranteed to be inside
    /// the corridor when `radius >= matchRadius + tolerance`. `decimate` widens its tolerance
    /// when a route will not fit the point budget, which is exactly why this is a function of
    /// the tolerance actually achieved: a constant 30 stops covering the polyline the moment
    /// one doubling takes the tolerance past 10, and the uncovered stretches then fall
    /// silently through to the route average with nothing to say so.
    static func queryRadius(forTolerance tolerance: CLLocationDistance) -> Int {
        Int((matchRadius + tolerance).rounded(.up))
    }

    /// A decimated polyline together with the tolerance it actually cost.
    struct Decimated {
        let coordinates: [CLLocationCoordinate2D]
        let tolerance: CLLocationDistance
    }

    /// Douglas–Peucker. Keeps the corridor on the road: the algorithm's own error metric is
    /// perpendicular deviation, which is precisely what Overpass's `around` measures.
    ///
    /// Over-budget results widen the tolerance rather than truncating the list. Cutting the
    /// tail off is the one thing that must not happen here — the query would then cover
    /// everything but the end of the route. The tolerance reached comes back with the points
    /// because the corridor radius has to be derived from it.
    static func decimate(
        _ coordinates: [CLLocationCoordinate2D],
        tolerance: CLLocationDistance,
        limit: Int
    ) -> Decimated {
        // A non-finite coordinate reaching `Int(floor(x / cellSize))` or the cache key's
        // `Int(lat * 100_000)` traps rather than misbehaves, and provenance is the only thing
        // keeping one out today.
        let finite = coordinates.filter {
            $0.latitude.isFinite && $0.longitude.isFinite
                && abs($0.latitude) <= 90 && abs($0.longitude) <= 180
        }
        guard finite.count > 2, limit >= 2 else { return Decimated(coordinates: finite, tolerance: tolerance) }
        let projection = Projection(origin: finite[0])
        let xs = finite.map { projection.x($0.longitude) }
        let ys = finite.map { projection.y($0.latitude) }

        var achieved = max(tolerance, 0.5)
        var kept = simplify(xs: xs, ys: ys, tolerance: achieved)
        while kept.count > limit, achieved < 200_000 {
            achieved *= 2
            kept = simplify(xs: xs, ys: ys, tolerance: achieved)
        }
        return Decimated(coordinates: kept.map { finite[$0] }, tolerance: achieved)
    }

    /// Cumulative arc length along a polyline, in the one metric both this matcher and
    /// `RoutePacer` use.
    ///
    /// They have to agree exactly. The profile keys its zones by distance and the pacer walks
    /// by distance, so a metric that disagrees by even a percent puts every zone boundary a
    /// few hundred metres off by the end of a long route. Flat equirectangular rather than
    /// `CLLocation.distance(from:)` because the pacer builds this on the main actor when a
    /// Follow starts, and two object allocations per point over 20,000 points is tens of
    /// milliseconds of stall before anything moves.
    static func arcLengths(_ coordinates: [CLLocationCoordinate2D]) -> [CLLocationDistance] {
        var lengths = [CLLocationDistance](repeating: 0, count: coordinates.count)
        guard coordinates.count > 1 else { return lengths }
        let projection = Projection(origin: coordinates[0])
        var previousX = projection.x(coordinates[0].longitude)
        var previousY = projection.y(coordinates[0].latitude)
        for index in 1..<coordinates.count {
            let x = projection.x(coordinates[index].longitude)
            let y = projection.y(coordinates[index].latitude)
            let leg = ((x - previousX) * (x - previousX) + (y - previousY) * (y - previousY)).squareRoot()
            // A non-finite leg would poison every distance after it, and this array has to
            // stay finite and monotonic for the zone lookup and the pacer's arithmetic.
            lengths[index] = lengths[index - 1] + (leg.isFinite ? leg : 0)
            previousX = x
            previousY = y
        }
        return lengths
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

        let cumulative = arcLengths(route)
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
            // `Int(floor(_:))` traps on non-finite values *and* on anything outside `Int`'s
            // range, so finiteness alone is not the guard this needs — it wants a magnitude
            // bound. Way coordinates get one from the decoder; route coordinates never have.
            // A point this far out cannot be within `matchRadius` of anything anyway, and
            // unmatched is a state the fallback chain already covers. `.magnitude <` is also
            // false for NaN, so this subsumes the finiteness check.
            guard px.magnitude < Self.maxProjectedMagnitude,
                  py.magnitude < Self.maxProjectedMagnitude else { continue }
            let bearing = routeBearing(rx: rx, ry: ry, at: index)
            let cell = Segments.cellKey(Int(floor(px / cellSize)), Int(floor(py / cellSize)))
            guard let bucket = segments.grid[cell] else { continue }

            var bestScore = Double.greatestFiniteMagnitude
            var best: Int32 = -1
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
                // sqrt only for candidates that already passed both gates: the hysteresis
                // bonus is in metres and cannot be applied to a square.
                var score = distanceSquared.squareRoot()
                if segments.way[segment] == previousWay { score -= hysteresisBonus }
                if score < bestScore {
                    bestScore = score
                    best = segments.way[segment]
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
            // Scanned in window order with a strict `>`, so the incumbent survives a tie and
            // the earliest neighbour wins among equals. Iterating `counts` instead made the
            // answer depend on Swift's per-process hash seed, which made this function's
            // output differ between launches on identical input.
            for neighbour in lower...upper {
                let id = ids[neighbour]
                let count = counts[id] ?? 0
                if count > bestCount {
                    bestID = id
                    bestCount = count
                }
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

        /// The longitude delta is wrapped into ±180 before scaling. A route across the 180th
        /// meridian steps from +179.99 to −179.99, which is 0.02° of ground and 359.98° of
        /// arithmetic — unwrapped, that single leg reads as ~40,000 km, and the pacer then
        /// walks it forever in 40 m steps, sweeping the device across the planet. Real on
        /// Taveuni, Fiji, where the meridian crosses roads people drive; `MapHomeView.frame()`
        /// guards the same case for the camera.
        func x(_ longitude: Double) -> Double {
            var delta = longitude - lon0
            if delta > 180 {
                delta -= 360
            } else if delta < -180 {
                delta += 360
            }
            return delta * xScale
        }

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
            // Inflating the bounding box by the match radius before insertion is what makes a
            // single-cell lookup complete: every point within `matchRadius` of this segment
            // falls inside the inflated box, so its own cell already holds this index.
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
