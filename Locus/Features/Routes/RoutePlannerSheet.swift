import CoreLocation
import MapKit
import SwiftUI

struct RoutePlannerSheet: View {
    @Binding var start: CLLocationCoordinate2D?
    @Binding var end: CLLocationCoordinate2D?
    @Binding var isRouting: Bool
    /// Confirmation of the currently loaded route; nil when none is loaded.
    var status: String?
    /// What the route will actually start from, including the implicit "wherever you are"
    /// when `start` is nil. Shown rather than silently used, since a route from the wrong
    /// place is the failure that is hardest to spot on a map.
    var resolvedStart: CLLocationCoordinate2D?
    /// Every route MapKit offered for the current endpoints, quickest first. Empty until
    /// a build succeeds.
    var candidates: [RoadRoute]
    var selectedRouteID: RoadRoute.ID?
    var onBuild: () -> Void
    var onSelectRoute: (RoadRoute) -> Void
    var onPlay: () -> Void
    var onImportGPX: () -> Void
    var onExportGPX: () -> Void
    var onUseDrawn: () -> Void

    @EnvironmentObject private var session: SpoofSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let status {
                    Section {
                        Label(status, systemImage: "checkmark.circle.fill")
                            .font(.footnote)
                            .foregroundStyle(LocusTheme.statusGood)
                    }
                }

                Section("Road route") {
                    LabeledContent(start == nil ? "Start (current)" : "Start") {
                        Text(coordText(resolvedStart)).font(.caption.monospaced())
                    }
                    LabeledContent("End") {
                        Text(coordText(end)).font(.caption.monospaced())
                    }
                    Button("Set start to pin") {
                        start = session.pin
                    }
                    .disabled(session.pin == nil)
                    Button("Start from current location") {
                        start = nil
                    }
                    .disabled(start == nil)
                    Button("Set end to pin") {
                        end = session.pin
                    }
                    .disabled(session.pin == nil)
                    Button("Swap start and end") {
                        // Written out rather than swap(&start, &end): those are property
                        // wrapper accessors, not storage, and an inout pair over them is
                        // an exclusivity trap for no gain.
                        let previousStart = resolvedStart
                        start = end
                        end = previousStart
                    }
                    .disabled(resolvedStart == nil || end == nil)
                    Button {
                        onBuild()
                    } label: {
                        if isRouting {
                            ProgressView()
                        } else {
                            Label("Build walk/drive route on roads", systemImage: "road.lanes")
                        }
                    }
                    .disabled(isRouting)
                }

                if !candidates.isEmpty {
                    Section("Choose a route") {
                        ForEach(Array(candidates.enumerated()), id: \.element.id) { index, route in
                            Button {
                                onSelectRoute(route)
                            } label: {
                                routeRow(route, isFastest: index == 0)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Section("Play / draw / GPX") {
                    Button {
                        onUseDrawn()
                    } label: {
                        Label("Use drawn path from map", systemImage: "pencil.tip")
                    }
                    Button(action: onPlay) {
                        Label("Follow route", systemImage: "play.fill")
                    }
                    Button(action: onImportGPX) {
                        Label("Import GPX", systemImage: "square.and.arrow.down")
                    }
                    Button(action: onExportGPX) {
                        Label("Export GPX", systemImage: "square.and.arrow.up")
                    }
                }

                Section {
                    Text("Routes come from Apple Maps directions for the selected travel mode. "
                         + "Alternates are ranked by travel time, so the top one is the route "
                         + "Maps would suggest. Speed gets light random variation so motion "
                         + "looks less robotic.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Routes")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func routeRow(_ route: RoadRoute, isFastest: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(route.name.isEmpty ? "Route" : route.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    if isFastest {
                        Text("Fastest")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(LocusTheme.accent.opacity(0.22)))
                    }
                }
                Text("\(Self.distanceText(route.distance)) · \(Self.durationText(route.expectedTravelTime))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: route.id == selectedRouteID ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(route.id == selectedRouteID ? LocusTheme.accent : .secondary)
        }
        .contentShape(Rectangle())
    }

    private func coordText(_ c: CLLocationCoordinate2D?) -> String {
        guard let c else { return "—" }
        return String(format: "%.5f, %.5f", c.latitude, c.longitude)
    }

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

    static func distanceText(_ meters: CLLocationDistance) -> String {
        distanceFormatter.string(fromDistance: meters)
    }

    static func durationText(_ seconds: TimeInterval) -> String {
        // Anything under a minute formats as an empty string with .hour/.minute units,
        // which would render as a bare separator dot.
        guard seconds >= 60 else { return "< 1 min" }
        return durationFormatter.string(from: seconds) ?? "—"
    }
}
