import CoreLocation
import Foundation

/// Turns a route's geometry and its speed profile into a stream of applies.
///
/// Pure and synchronous, so the follower's `Task` does nothing but sleep, check cancellation,
/// and hand a coordinate to `request(...)`. It also resamples the polyline by arc length,
/// which replaces both the old per-leg sub-stepping and the 0.05 s delay floor: the cadence
/// is now a property of speed rather than of however densely the source happened to be
/// sampled, so a hand-drawn path with 1 m legs and a long route with 40 m legs get the same
/// treatment.
struct RoutePacer {
    struct Step {
        let coordinate: CLLocationCoordinate2D
        /// Seconds to sleep *before* applying this coordinate.
        let delay: TimeInterval
        /// Nil without a profile: there is no limit in force, and a travel-mode speed
        /// dressed up as one would be a claim the app cannot make.
        let reading: SpeedReading?
    }

    static let accel: Double = 1.4          // m/s², comfortable acceleration
    static let decel: Double = 2.2          // m/s², comfortable braking
    static let initialSpeed: Double = 3.0   // m/s; a true standing start reads as a hang
    static let minSpeed: Double = 0.8       // the existing floor in followRoute, preserved
    static let applyBudget: TimeInterval = 0.35   // target simulated seconds per apply
    static let minStep: CLLocationDistance = 4
    static let maxStep: CLLocationDistance = 40
    static let zoneJitter: ClosedRange<Double> = 0.94...1.06   // with a profile, per zone
    static let legJitter: ClosedRange<Double> = 0.88...1.12    // without, per step: unchanged

    private let coordinates: [CLLocationCoordinate2D]
    private let cumulative: [CLLocationDistance]
    private let total: CLLocationDistance
    private let profile: SpeedProfile?
    private let mode: TravelMode

    private var traveled: CLLocationDistance = 0
    private var speed: Double = RoutePacer.initialSpeed
    private var legIndex = 0
    private var zoneCursor = 0
    private var zoneFactor: Double?
    private var finished = false

    init(coordinates: [CLLocationCoordinate2D], profile: SpeedProfile?, mode: TravelMode) {
        self.coordinates = coordinates
        self.profile = profile
        self.mode = mode
        var lengths = [CLLocationDistance](repeating: 0, count: coordinates.count)
        for index in 1..<max(1, coordinates.count) {
            let previous = CLLocation(latitude: coordinates[index - 1].latitude, longitude: coordinates[index - 1].longitude)
            let current = CLLocation(latitude: coordinates[index].latitude, longitude: coordinates[index].longitude)
            lengths[index] = lengths[index - 1] + previous.distance(from: current)
        }
        cumulative = lengths
        total = lengths.last ?? 0
    }

    /// nil once the final coordinate has been emitted.
    mutating func next() -> Step? {
        guard !finished, coordinates.count >= 2, total > traveled else { return nil }

        let target = targetSpeed(at: traveled)
        let remaining = total - traveled
        let distance = min(remaining, min(max(speed * Self.applyBudget, Self.minStep), Self.maxStep))

        var allowed = target
        // Brake *before* the sign rather than after it. The sqrt term exceeds the current
        // speed past `horizon` metres and can no longer constrain, so the scan stops there.
        if let profile {
            let horizon = speed * speed / (2 * Self.decel)
            var index = zoneCursor + 1
            while index < profile.zones.count {
                let gap = profile.zones[index].start - traveled
                if gap <= 0 {
                    index += 1
                    continue
                }
                guard gap <= horizon else { break }
                let zoneSpeed = profile.zones[index].speed
                allowed = min(allowed, (zoneSpeed * zoneSpeed + 2 * Self.decel * gap).squareRoot())
                index += 1
            }
        }

        var nextSpeed: Double
        if allowed > speed {
            nextSpeed = min(allowed, (speed * speed + 2 * Self.accel * distance).squareRoot())
        } else {
            nextSpeed = max(allowed, max(0, speed * speed - 2 * Self.decel * distance).squareRoot())
        }
        nextSpeed = max(nextSpeed, Self.minSpeed)

        // Exact for constant acceleration over a fixed distance, which is the reason the
        // pacer steps by distance: stepping by time makes dt depend on the mean speed, which
        // depends on dt.
        let delay = 2 * distance / (speed + nextSpeed)

        traveled += distance
        speed = nextSpeed
        // The final coordinate is emitted exactly, never an interpolation short of it.
        let landed = traveled >= total
        if landed { finished = true }
        let coordinate = landed ? coordinates[coordinates.count - 1] : interpolated(at: traveled)

        return Step(coordinate: coordinate, delay: delay, reading: reading())
    }

    /// Current zone's speed with a jitter factor drawn once per zone and held for it. A
    /// per-step draw would make the speed rattle rather than vary.
    private mutating func targetSpeed(at distance: CLLocationDistance) -> Double {
        guard let profile else {
            return max(Self.minSpeed, mode.baseSpeed * Double.random(in: Self.legJitter))
        }
        let index = profile.zoneIndex(at: distance, from: zoneCursor)
        if index != zoneCursor || zoneFactor == nil {
            zoneCursor = index
            zoneFactor = Double.random(in: Self.zoneJitter)
        }
        return profile.zones[index].speed * (zoneFactor ?? 1)
    }

    private func reading() -> SpeedReading? {
        guard let profile, zoneCursor < profile.zones.count else { return nil }
        let zone = profile.zones[zoneCursor]
        return SpeedReading(
            speed: zone.speed,
            source: zone.source,
            roadName: zone.roadName,
            unit: profile.unit
        )
    }

    private mutating func interpolated(at distance: CLLocationDistance) -> CLLocationCoordinate2D {
        while legIndex + 2 < coordinates.count, cumulative[legIndex + 1] <= distance {
            legIndex += 1
        }
        let a = coordinates[legIndex]
        let b = coordinates[legIndex + 1]
        let span = cumulative[legIndex + 1] - cumulative[legIndex]
        let t = span > 0 ? min(1, max(0, (distance - cumulative[legIndex]) / span)) : 1
        return CLLocationCoordinate2D(
            latitude: a.latitude + (b.latitude - a.latitude) * t,
            longitude: a.longitude + (b.longitude - a.longitude) * t
        )
    }
}
