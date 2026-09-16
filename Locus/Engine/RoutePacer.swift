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
    private var started = false
    private var legIndex = 0
    private var zoneCursor = 0
    private var zoneFactor: Double?
    private var finished = false

    init(coordinates: [CLLocationCoordinate2D], profile: SpeedProfile?, mode: TravelMode) {
        self.coordinates = coordinates
        self.profile = profile
        self.mode = mode
        // The matcher keys zones by distance measured this same way. Any other metric here
        // and every zone boundary lands somewhere the profile did not put it.
        cumulative = SpeedLimitMatcher.arcLengths(coordinates)
        total = cumulative.last ?? 0
    }

    /// nil once the final coordinate has been emitted.
    mutating func next() -> Step? {
        guard !finished, coordinates.count >= 2, total > traveled else { return nil }
        guard let profile else { return unpacedStep() }

        let target = targetSpeed(in: profile, at: traveled)
        if !started {
            started = true
            // A standing start reads as a hang, but opening above the first zone's limit is
            // the same artefact pointing the other way — a jump start on a 20 km/h street.
            speed = min(speed, target)
        }
        let distance = min(total - traveled, min(max(speed * Self.applyBudget, Self.minStep), Self.maxStep))

        var allowed = target
        // Brake *before* the sign rather than after it. The sqrt term exceeds the current
        // speed past `horizon` metres and can no longer constrain, so the scan stops there.
        let horizon = speed * speed / (2 * Self.decel)
        var index = zoneCursor + 1
        while index < profile.zones.count {
            // Measured from where this step ENDS, because `allowed` constrains the speed at
            // the end of it. Measuring from the start instead makes the constraint equal the
            // current speed the moment the vehicle lands on the braking curve, and `max`
            // below then holds it there — so it rides the curve without ever descending it
            // and arrives metres inside the slower zone still doing motorway speed. The
            // end-of-step gap makes `allowed` exactly the decel-limited speed instead, which
            // is the trajectory that actually reaches the limit at the sign.
            let gap = profile.zones[index].start - (traveled + distance)
            // Aim at the bottom of the jitter range, not the nominal limit: entry draws a
            // fresh factor that can be 6% under, and arriving exactly on the nominal number
            // would then be overspeed.
            let zoneSpeed = profile.zones[index].speed * Self.zoneJitter.lowerBound
            guard gap > 0 else {
                // The boundary falls inside this step, so the step has to end at its speed.
                allowed = min(allowed, zoneSpeed)
                index += 1
                continue
            }
            guard gap <= horizon else { break }
            allowed = min(allowed, (zoneSpeed * zoneSpeed + 2 * Self.decel * gap).squareRoot())
            index += 1
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
        speed = nextSpeed
        return advance(by: distance, delay: delay, reading: reading(in: profile))
    }

    /// The no-profile path: one flat speed per step and no slew limiting at all.
    ///
    /// The ramp exists to smooth the step changes a profile introduces, and there are none
    /// here — the target is redrawn every step from the same ±12% spread the old follower
    /// used. Running the limiter over that spread does not smooth it, it *biases* it: the
    /// per-step slew allowance is narrower than the jitter, and braking is faster than
    /// accelerating, so the speed equilibrates below the target's mean and stays there for
    /// the whole route. Measured at roughly 1.4% slow, which is 1.4% this path must not be.
    private mutating func unpacedStep() -> Step {
        let target = max(Self.minSpeed, mode.baseSpeed * Double.random(in: Self.legJitter))
        let distance = min(total - traveled, min(max(target * Self.applyBudget, Self.minStep), Self.maxStep))
        speed = target
        return advance(by: distance, delay: distance / target, reading: nil)
    }

    private mutating func advance(
        by distance: CLLocationDistance,
        delay: TimeInterval,
        reading: SpeedReading?
    ) -> Step {
        traveled += distance
        // The final coordinate is emitted exactly, never an interpolation short of it.
        let landed = traveled >= total
        if landed { finished = true }
        let coordinate = landed ? coordinates[coordinates.count - 1] : interpolated(at: traveled)
        return Step(coordinate: coordinate, delay: delay, reading: reading)
    }

    /// Current zone's speed with a jitter factor drawn once per zone and held for it. A
    /// per-step draw would make the speed rattle rather than vary.
    private mutating func targetSpeed(in profile: SpeedProfile, at distance: CLLocationDistance) -> Double {
        let index = profile.zoneIndex(at: distance, from: zoneCursor)
        if index != zoneCursor || zoneFactor == nil {
            zoneCursor = index
            zoneFactor = Double.random(in: Self.zoneJitter)
        }
        return profile.zones[index].speed * (zoneFactor ?? 1)
    }

    private func reading(in profile: SpeedProfile) -> SpeedReading? {
        guard zoneCursor < profile.zones.count else { return nil }
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
