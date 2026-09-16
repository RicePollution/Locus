import CoreLocation
import Foundation

/// The unit the source data posted its limits in. Display only — every speed inside the
/// engine is metres per second, because that is what `CLLocationSpeed` and the follower's
/// arithmetic already are, and converting in one place at the edge beats converting in ten.
enum SpeedUnit {
    case kilometresPerHour
    case milesPerHour
}

extension SpeedUnit {
    /// Territories that post limits in miles per hour. Static reference data, not logic.
    /// It is keyed off the route's own geography rather than `Locale.current`, which says
    /// nothing at all about where a spoofed route is.
    static let mphCountryCodes: Set<String> = [
        "US", "GB", "UK", "LR", "MM", "VG", "KY", "BS", "BZ", "AG", "DM", "GD", "KN",
        "LC", "VC", "MS", "AI", "TC", "FK", "SH", "GG", "JE", "IM", "WS", "PR", "GU",
        "VI", "AS", "MP"
    ]

    static func forCountryCode(_ code: String) -> SpeedUnit {
        mphCountryCodes.contains(code.uppercased()) ? .milesPerHour : .kilometresPerHour
    }

    func metresPerSecond(_ value: Double) -> CLLocationSpeed {
        switch self {
        case .milesPerHour: return value * 0.44704
        case .kilometresPerHour: return value / 3.6
        }
    }

    func value(fromMetresPerSecond speed: CLLocationSpeed) -> Double {
        switch self {
        case .milesPerHour: return speed / 0.44704
        case .kilometresPerHour: return speed * 3.6
        }
    }

    var abbreviation: String {
        switch self {
        case .milesPerHour: return "mph"
        case .kilometresPerHour: return "km/h"
        }
    }
}

/// Where a zone's speed came from, in the order the fallback chain tries them.
///
/// This is carried all the way to the UI on purpose. "30 mph" and "probably 30 mph" should
/// not read the same, and when someone reports that a road ran at the wrong speed the first
/// question is which link of the chain produced the number.
enum SpeedSource: Int, Comparable {
    /// Parsed from an OSM `maxspeed` value. The only one that is a *posted* limit.
    case posted = 0
    /// The `highway=` class default for the inferred unit system. Carries most of the route.
    case impliedByClass = 1
    /// `RoadRoute.averageSpeed` — Apple's own number for this route, already traffic-aware.
    case routeAverage = 2
    /// `TravelMode.baseSpeed` — exactly what the app did before this feature existed.
    case travelMode = 3

    static func < (a: SpeedSource, b: SpeedSource) -> Bool { a.rawValue < b.rawValue }
}

/// A route's speed as a function of distance travelled along one specific coordinate array.
///
/// Keyed by metres-along-route rather than by point index deliberately: the same geometry
/// gets resampled at several spacings in this app (`spacing(forRouteLength:)`, the GPX path's
/// fixed 10 m), and an index-parallel array silently desynchronises when that happens while a
/// distance-keyed one stays correct. It is also three orders of magnitude smaller — a route
/// has tens of zones, not 19,000 points.
struct SpeedProfile {
    struct Zone {
        /// Metres from the first coordinate to where this zone begins. Zone i covers
        /// `[start, zones[i+1].start)`; the last runs to `routeLength`.
        let start: CLLocationDistance
        /// Metres per second, already clamped to `[minZoneSpeed, maxZoneSpeed]`.
        let speed: CLLocationSpeed
        let source: SpeedSource
        /// OSM `name`, else `ref`, else empty. For the follow-time readout only.
        let roadName: String
    }

    private(set) var zones: [Zone]
    let routeLength: CLLocationDistance
    let unit: SpeedUnit
    /// Share of `routeLength` whose speed came from a parsed `maxspeed`. Shown in the
    /// planner because it is the honest measure of how much of this is real data.
    let postedCoverage: Double

    static let minZoneSpeed: CLLocationSpeed = 1.5      //  5.4 km/h
    static let maxZoneSpeed: CLLocationSpeed = 55.0     //  198 km/h; a hard sanity ceiling
    static let unlimitedSpeed: CLLocationSpeed = 41.7   //  150 km/h, used for maxspeed=none
    static let minZoneLength: CLLocationDistance = 40

    /// Two zone speeds this close are the same zone. The matcher already quantises to
    /// 0.1 m/s; this is the same grid, expressed as the tolerance a comparison needs.
    private static let speedEpsilon: CLLocationSpeed = 0.05

    /// The only way to build one. Sorts, drops zeroes, merges adjacent zones with equal
    /// speed, merges any zone shorter than `minZoneLength`, and prepends a fallback zone at
    /// 0 if the matcher produced none — so "empty", "unsorted" and "starts at 40 m" are not
    /// states the rest of the code has to handle.
    init(
        rawZones: [Zone],
        routeLength: CLLocationDistance,
        unit: SpeedUnit,
        fallback: CLLocationSpeed,
        fallbackSource: SpeedSource
    ) {
        self.routeLength = max(0, routeLength.isFinite ? routeLength : 0)
        self.unit = unit

        let fallbackZone = Zone(
            start: 0,
            speed: Self.clamp(fallback),
            source: fallbackSource,
            roadName: ""
        )
        var prepared = rawZones
            .filter { $0.start.isFinite && $0.start >= 0 && $0.speed.isFinite && $0.speed > 0 }
            .map { Zone(start: $0.start, speed: Self.clamp($0.speed), source: $0.source, roadName: $0.roadName) }
            .sorted { $0.start < $1.start }
        if prepared.first.map({ $0.start > 0 }) ?? true {
            prepared.insert(fallbackZone, at: 0)
        }

        var merged: [Zone] = []
        merged.reserveCapacity(prepared.count)
        for zone in prepared {
            // A boundary this close behind reveals the trailing zone as a run too short to
            // be a real speed change, so it gives way to the zone before it.
            while merged.count > 1, zone.start - merged[merged.count - 1].start < Self.minZoneLength {
                merged.removeLast()
            }
            guard let last = merged.last else {
                merged.append(zone)
                continue
            }
            if abs(last.speed - zone.speed) < Self.speedEpsilon {
                // The run simply continues. Keep the weaker of the two sources so
                // `postedCoverage` can never over-claim how much of this is real data.
                merged[merged.count - 1] = Zone(
                    start: last.start,
                    speed: last.speed,
                    source: max(last.source, zone.source),
                    roadName: last.roadName.isEmpty ? zone.roadName : last.roadName
                )
                continue
            }
            // Only reachable while `merged` is just the opening zone, since the loop above
            // has already retired any other short tail. The opening runs on through it, the
            // same "merge into the preceding zone" rule as everywhere else. Letting the
            // incoming zone claim the start instead made a *run* of short opening zones end
            // up with the last one's speed, which is nobody's reading of the data.
            if zone.start - last.start < Self.minZoneLength { continue }
            merged.append(zone)
        }
        zones = merged

        var posted: CLLocationDistance = 0
        for (index, zone) in merged.enumerated() where zone.source == .posted {
            let end = index + 1 < merged.count ? merged[index + 1].start : self.routeLength
            posted += max(0, min(end, self.routeLength) - zone.start)
        }
        postedCoverage = self.routeLength > 0 ? min(1, posted / self.routeLength) : 0
    }

    /// Zone covering `distance`, searched forward from `hint`. The follower's distance is
    /// monotonic, so passing the previous index makes every lookup O(1) amortised and keeps
    /// the hot loop free of binary searches.
    func zoneIndex(at distance: CLLocationDistance, from hint: Int) -> Int {
        var index = min(max(hint, 0), zones.count - 1)
        while index > 0, zones[index].start > distance { index -= 1 }
        while index + 1 < zones.count, zones[index + 1].start <= distance { index += 1 }
        return index
    }

    /// Seconds this profile implies for the whole route, ignoring acceleration. Shown next
    /// to MapKit's ETA because the two will differ and a user who spots that deserves the
    /// number rather than a surprise.
    var impliedDuration: TimeInterval {
        var total: TimeInterval = 0
        for (index, zone) in zones.enumerated() {
            let end = index + 1 < zones.count ? zones[index + 1].start : routeLength
            total += max(0, end - zone.start) / zone.speed
        }
        return total
    }

    static func clamp(_ speed: CLLocationSpeed) -> CLLocationSpeed {
        guard speed.isFinite else { return minZoneSpeed }
        return min(maxZoneSpeed, max(minZoneSpeed, speed))
    }
}

/// What the UI shows while following. `Equatable` so the follower can assign only on change
/// — it steps up to three times a second and a zone boundary arrives perhaps twice a minute.
struct SpeedReading: Equatable {
    let speed: CLLocationSpeed
    let source: SpeedSource
    let roadName: String
    let unit: SpeedUnit

    /// "30 mph", or "~30 mph" when `source != .posted`. The tilde is the whole point: it is
    /// the difference between a fact and our guess, and it costs one character.
    var displayText: String {
        let rounded = Int(unit.value(fromMetresPerSecond: speed).rounded())
        let prefix = source == .posted ? "" : "~"
        return "\(prefix)\(rounded) \(unit.abbreviation)"
    }
}

enum HighwayClass: String, CaseIterable {
    case motorway, trunk, primary, secondary, tertiary
    case unclassified, residential
    case livingStreet = "living_street"
    case service

    /// `motorway_link` → `.motorway` with `isLink == true`. Links are slip roads: they carry
    /// the parent's class but never the parent's speed.
    static func parse(_ osmValue: String) -> (class: HighwayClass, isLink: Bool)? {
        var value = osmValue.trimmingCharacters(in: .whitespaces).lowercased()
        var isLink = false
        if value.hasSuffix("_link") {
            isLink = true
            value = String(value.dropLast("_link".count))
        }
        guard let parsed = HighwayClass(rawValue: value) else { return nil }
        return (parsed, isLink)
    }

    /// Plausible default for this class in this unit system. Not authoritative and not
    /// claimed to be: these numbers exist because between 48% and 71% of the ways on a real
    /// route carry no `maxspeed` at all, so this table drives most of the route.
    func defaultSpeed(unit: SpeedUnit, isLink: Bool) -> CLLocationSpeed {
        let posted: Double
        switch unit {
        case .kilometresPerHour:
            switch self {
            case .motorway: posted = 120
            case .trunk: posted = 100
            case .primary: posted = 90
            case .secondary: posted = 80
            case .tertiary: posted = 70
            case .unclassified: posted = 60
            case .residential: posted = 50
            case .livingStreet: posted = 20
            case .service: posted = 20
            }
        case .milesPerHour:
            switch self {
            case .motorway: posted = 70
            case .trunk: posted = 65
            case .primary: posted = 55
            case .secondary: posted = 50
            case .tertiary: posted = 45
            case .unclassified: posted = 35
            case .residential: posted = 25
            case .livingStreet: posted = 15
            case .service: posted = 15
            }
        }
        guard isLink else { return unit.metresPerSecond(posted) }
        let linkFloor: Double = unit == .milesPerHour ? 20 : 30
        return unit.metresPerSecond(max(linkFloor, posted * 0.6))
    }
}

enum MaxspeedParser {
    /// Everything one raw tag value can tell us. `speed == nil` means "fall through to the
    /// class default" — the hints are still useful even then, which is why this is a struct
    /// and not an optional speed.
    struct Outcome {
        let speed: CLLocationSpeed?
        /// Set when the value named its unit ("30 mph") — feeds unit inference.
        let unitHint: SpeedUnit?
        /// Two-letter prefix of an implicit value ("GB:nsl_single" → "GB") — feeds unit
        /// inference more reliably than the unit suffix does, since implicit values are the
        /// ones that omit units.
        let countryHint: String?
        /// Set by an implicit zone keyword ("DE:urban" → .residential), so a way with an
        /// implicit value gets a better default than its `highway=` class alone would give.
        let classHint: (class: HighwayClass, isLink: Bool)?

        static let empty = Outcome(speed: nil, unitHint: nil, countryHint: nil, classHint: nil)
    }

    /// OSM's `walk` convention. Not a posted number anywhere, but it is a real constraint.
    static let walkingSpeed: CLLocationSpeed = 7 / 3.6
    /// Junk gate. Anything past this on a `highway=*` is a data error, not a fast road.
    static let maxParsableSpeed: CLLocationSpeed = 300 / 3.6

    static func parse(_ raw: String) -> Outcome {
        let normalized = raw.lowercased().trimmingCharacters(in: .whitespaces)
        guard !normalized.isEmpty else { return .empty }

        var speed: CLLocationSpeed?
        var unitHint: SpeedUnit?
        var countryHint: String?
        var classHint: (class: HighwayClass, isLink: Bool)?
        for part in normalized.split(separator: ";") {
            let outcome = parsePart(part.trimmingCharacters(in: .whitespaces))
            if let partSpeed = outcome.speed {
                // A bare "50;30" is malformed OSM whichever reading you take; the lower one
                // is the only one that cannot be an over-claim.
                speed = min(speed ?? partSpeed, partSpeed)
            }
            unitHint = unitHint ?? outcome.unitHint
            countryHint = countryHint ?? outcome.countryHint
            classHint = classHint ?? outcome.classHint
        }
        return Outcome(speed: speed, unitHint: unitHint, countryHint: countryHint, classHint: classHint)
    }

    private static func parsePart(_ value: String) -> Outcome {
        guard !value.isEmpty else { return .empty }
        switch value {
        case "none":
            // Genuinely unbounded makes the follower teleport, so the autobahn is bounded
            // here and nowhere else.
            return Outcome(speed: SpeedProfile.unlimitedSpeed, unitHint: nil, countryHint: nil, classHint: nil)
        case "walk":
            return Outcome(speed: walkingSpeed, unitHint: nil, countryHint: nil, classHint: nil)
        case "signals", "variable", "no", "unposted", "default", "unknown":
            // The posted value is dynamic or absent and we do not have it. Falling through
            // to the class default is the honest answer.
            return .empty
        default:
            break
        }
        if value.hasPrefix("zone") {
            return parseZoneNumber(value, unit: .kilometresPerHour, country: nil)
        }
        if let colon = value.firstIndex(of: ":") {
            let prefix = value[value.startIndex..<colon]
            if prefix.count == 2, prefix.allSatisfy({ $0.isASCII && $0.isLetter }) {
                return parseImplicit(
                    country: prefix.uppercased(),
                    zone: String(value[value.index(after: colon)...])
                )
            }
        }
        return parseNumeric(value)
    }

    private static func parseImplicit(country: String, zone rawZone: String) -> Outcome {
        let zone = rawZone.trimmingCharacters(in: .whitespaces)
        func hinting(_ hint: (class: HighwayClass, isLink: Bool)?) -> Outcome {
            Outcome(speed: nil, unitHint: nil, countryHint: country, classHint: hint)
        }
        switch zone {
        case "urban": return hinting((.residential, false))
        case "rural": return hinting((.secondary, false))
        case "motorway": return hinting((.motorway, false))
        case "trunk": return hinting((.trunk, false))
        case "living_street": return hinting((.livingStreet, false))
        case "walk":
            return Outcome(speed: walkingSpeed, unitHint: nil, countryHint: country, classHint: nil)
        // Exact, common, and not derivable from the class table — worth the three cases.
        case "nsl_single":
            return Outcome(speed: SpeedUnit.milesPerHour.metresPerSecond(60), unitHint: .milesPerHour, countryHint: country, classHint: nil)
        case "nsl_dual":
            return Outcome(speed: SpeedUnit.milesPerHour.metresPerSecond(70), unitHint: .milesPerHour, countryHint: country, classHint: nil)
        case "nsl_restricted":
            return Outcome(speed: SpeedUnit.milesPerHour.metresPerSecond(30), unitHint: .milesPerHour, countryHint: country, classHint: nil)
        default:
            break
        }
        // An implicit value names no unit, so the country prefix is what decides it.
        return parseZoneNumber(zone, unit: SpeedUnit.forCountryCode(country), country: country)
    }

    private static func parseZoneNumber(_ rawZone: String, unit: SpeedUnit, country: String?) -> Outcome {
        var digits = rawZone
        if digits.hasPrefix("zone") { digits = String(digits.dropFirst("zone".count)) }
        if digits.hasPrefix(":") { digits = String(digits.dropFirst()) }
        guard let value = Double(digits.trimmingCharacters(in: .whitespaces)),
              let speed = sanitised(unit.metresPerSecond(value)) else {
            return Outcome(speed: nil, unitHint: nil, countryHint: country, classHint: nil)
        }
        return Outcome(speed: speed, unitHint: nil, countryHint: country, classHint: nil)
    }

    private static func parseNumeric(_ value: String) -> Outcome {
        var digits = ""
        var index = value.startIndex
        while index < value.endIndex, value[index].isNumber || value[index] == "." {
            digits.append(value[index])
            index = value.index(after: index)
        }
        guard let number = Double(digits) else { return .empty }
        let suffix = value[index...].trimmingCharacters(in: .whitespaces)
        let unit: SpeedUnit
        let hint: SpeedUnit?
        switch suffix {
        case "mph":
            unit = .milesPerHour
            hint = .milesPerHour
        case "km/h", "kmh", "kph":
            unit = .kilometresPerHour
            hint = .kilometresPerHour
        case "":
            // Bare numbers are km/h by OSM definition. No unit hint: seeing one is only
            // weak evidence of a km/h region, and step 3 of inference weighs that instead.
            unit = .kilometresPerHour
            hint = nil
        default:
            // "knots" is a waterway tag and anything else is junk; both fall through.
            return .empty
        }
        guard let speed = sanitised(unit.metresPerSecond(number)) else { return .empty }
        return Outcome(speed: speed, unitHint: hint, countryHint: nil, classHint: nil)
    }

    private static func sanitised(_ speed: CLLocationSpeed) -> CLLocationSpeed? {
        guard speed.isFinite, speed > 0, speed <= maxParsableSpeed else { return nil }
        return speed
    }
}

enum SpeedLimitSettings {
    static let defaultsKey = "locus.useSpeedLimits"

    /// Defaults to true when the key is absent — `UserDefaults.bool(forKey:)` reports false
    /// for a missing key, which is the opposite of the shipped default.
    static var isEnabled: Bool {
        guard let stored = UserDefaults.standard.object(forKey: defaultsKey) as? Bool else { return true }
        return stored
    }

    static func setEnabled(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: defaultsKey)
    }
}
