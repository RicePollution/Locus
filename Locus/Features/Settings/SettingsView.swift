import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var pairing: PairingStore
    @EnvironmentObject private var session: SpoofSession
    @Environment(\.dismiss) private var dismiss

    @State private var showImporter = false
    @State private var showPairOnDevice = false
    @State private var showNameEasterEgg = false
    @State private var tunnelIP = TunnelConfig.targetIP
    @State private var localDevVPNInstalled = LocalDevVPN.isInstalled
    @State private var useSpeedLimits = SpeedLimitSettings.isEnabled
    @State private var probing = false
    @State private var probeReport: TunnelProbeReport?
    @Environment(\.scenePhase) private var scenePhase

    private var supportsOnDevicePairing: Bool {
        if #available(iOS 27.0, *) { return true }
        return false
    }

    private var tunnelReachability: TunnelReachability {
        LocalDevVPN.reachability(
            confirmedTarget: session.confirmedTunnelIP,
            proven: session.provenTunnelIPs.contains(TunnelConfig.targetIP)
        )
    }

    private var tunnelStatusLabel: String {
        switch tunnelReachability {
        case .confirmed: return "Connected"
        case .likely: return "Looks connected"
        case .unknown: return "Not detected"
        }
    }

    private var appVersion: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? short : "\(short) (\(build))"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label {
                        Text(pairing.hasPairingFile ? "RPPairing file installed" : "No pairing file")
                    } icon: {
                        Image(systemName: pairing.hasPairingFile ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(pairing.hasPairingFile ? LocusTheme.statusGood : LocusTheme.statusWarn)
                    }

                    if supportsOnDevicePairing {
                        Button {
                            showPairOnDevice = true
                        } label: {
                            Label("Pair on this iPhone", systemImage: "iphone.gen3.radiowaves.left.and.right")
                        }
                    }

                    Button("Import RPPairing file…") { showImporter = true }
                    Button("Paste RPPairing from clipboard") {
                        do {
                            try pairing.importPairingFromClipboard()
                        } catch {
                            session.lastError = error.localizedDescription
                        }
                    }
                    if pairing.hasPairingFile {
                        Button("Remove pairing file", role: .destructive) {
                            try? pairing.removePairing()
                        }
                    }
                } header: {
                    Text("Developer pairing")
                } footer: {
                    Text(supportsOnDevicePairing
                         ? "On iOS 27, use Pair on this iPhone — no computer. Locus advertises a pairable host; confirm the 6-digit code under Settings › Privacy & Security › Developer Mode › Pair with Host. On older iOS, import an RPPairing file from idevice_pair (not a SideStore lockdown .mobiledevicepairing). LiveContainer: enable Fix File Picker on Locus, or use Paste / Share → LiveContainer → Locus."
                         : "Import an RPPairing file from idevice_pair (not a SideStore lockdown .mobiledevicepairing). If the file picker fails (common in LiveContainer), enable Fix File Picker on the app, share the file into LiveContainer → Locus, or copy the plist and use Paste.")
                }

                Section {
                    TextField("Device tunnel IP", text: $tunnelIP)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit {
                            TunnelConfig.setTargetIP(tunnelIP)
                        }
                    LabeledContent("Status") {
                        Text(tunnelStatusLabel)
                            .foregroundStyle(tunnelReachability == .unknown ? LocusTheme.statusWarn : LocusTheme.statusGood)
                    }
                    if let port = session.activePort {
                        LabeledContent("Tunnel port", value: String(port))
                    } else if let port = session.lastTunnelPort {
                        LabeledContent("Tunnel port", value: "\(port) (last used)")
                    } else {
                        LabeledContent("Tunnel port", value: "—")
                    }
                    Button("Save tunnel IP") {
                        TunnelConfig.setTargetIP(tunnelIP)
                    }
                    Button {
                        if localDevVPNInstalled {
                            LocalDevVPN.openInstalled()
                        } else {
                            LocalDevVPN.openAppStore()
                        }
                    } label: {
                        Label(
                            localDevVPNInstalled ? "Open LocalDevVPN" : "Get LocalDevVPN (App Store)",
                            systemImage: localDevVPNInstalled ? "lock.shield.fill" : "arrow.down.app.fill"
                        )
                    }
                    Button {
                        runTunnelProbe()
                    } label: {
                        Label(probing ? "Testing tunnel…" : "Test tunnel", systemImage: "stethoscope")
                    }
                    .disabled(probing)
                    if let probeReport {
                        probeRows(probeReport)
                    }
                } header: {
                    Text("Tunnel")
                } footer: {
                    Text("Connect LocalDevVPN before teleporting. Default tunnel IP is 10.7.0.1. Start a spoof on Wi‑Fi first; it can keep working on cellular afterward. Proxies that keep the tunnel on loopback (Clash, SingBox) show as Not detected even when they work — teleporting is never blocked by this row. Test tunnel opens a plain TCP connection to each port the engine would try, sends nothing, and reports the raw errno — which separates packets that never arrived from a handshake that failed after they did.")
                }

                Section {
                    Toggle("Use posted speed limits", isOn: $useSpeedLimits)
                        .onChange(of: useSpeedLimits) { _, value in
                            SpeedLimitSettings.setEnabled(value)
                        }
                } header: {
                    Text("Driving")
                } footer: {
                    Text("Driving routes follow the posted limit for each road instead of one fixed speed, using OpenStreetMap data. Building a driving route sends the route's shape — a list of coordinates along it — to overpass-api.de, a free server run by volunteers. Stretches of the route that pass within 500 m of the position Locus has for your device are left out and never sent; those stretches use the fallback speed instead. That position is a coarse fix, and while a spoof is running Locus uses the last one it had before the spoof started. The server still sees your IP address and a User-Agent saying the request came from Locus. There is no account, no identifier, and nothing else is sent. A failed lookup never stops a route; it drives at the old fixed speed.")
                }

                Section("Privacy") {
                    Text("On-device by default. Favorites and recents stay in UserDefaults. No analytics, no accounts. The one exception is posted speed limits: with that setting on, building a driving route sends the route's shape to overpass-api.de. Stretches passing within 500 m of the position Locus has for your device are withheld, but the server does see your IP address and that the request came from Locus. Turn the setting off under Driving to send nothing at all.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("About") {
                    LabeledContent("Version", value: appVersion)
                    LabeledContent("Engine", value: "idevice DVT location simulation")
                    Text("Locus is free and open source (MIT). Location injection uses the MIT-licensed idevice FFI.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    // The ODbL requires the attribution wherever the data is used; the
                    // Overpass response body carries the same notice.
                    Text("Speed limit data © OpenStreetMap contributors, available under the ODbL.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button {
                        showNameEasterEgg = true
                    } label: {
                        Text("locus, n. — a place. From the Latin for where you are.")
                            .font(.footnote.italic())
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        TunnelConfig.setTargetIP(tunnelIP)
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showImporter) {
            PairingDocumentPicker(
                onPick: { url in
                    showImporter = false
                    do {
                        try pairing.importPairing(from: url)
                    } catch {
                        session.lastError = error.localizedDescription
                    }
                },
                onCancel: { showImporter = false }
            )
            .ignoresSafeArea()
        }
            .sheet(isPresented: $showPairOnDevice) {
                PairOnDeviceView()
                    .environmentObject(pairing)
            }
            .fullScreenCover(isPresented: $showNameEasterEgg) {
                LocusEasterEggView()
            }
            .onAppear {
                localDevVPNInstalled = LocalDevVPN.isInstalled
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    localDevVPNInstalled = LocalDevVPN.isInstalled
                }
            }
        }
    }

    /// Probes the IP as typed rather than as stored, so the field can be tested before it is
    /// saved. Nothing here touches the engine, so it is safe mid-session.
    private func runTunnelProbe() {
        probing = true
        probeReport = nil
        let target = tunnelIP
        Task {
            probeReport = await TunnelProbe.run(targetIP: target)
            probing = false
        }
    }

    @ViewBuilder
    private func probeRows(_ report: TunnelProbeReport) -> some View {
        switch report {
        case .invalidIP(let ip):
            VStack(alignment: .leading, spacing: 2) {
                Text(ip.isEmpty ? "No tunnel IP" : "\(ip) is not an IPv4 address")
                    .foregroundStyle(LocusTheme.statusBad)
                Text("Nothing was sent. Enter a dotted-quad address such as 10.7.0.1.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .probed(let ip, let results):
            ForEach(results) { result in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("\(ip):\(String(result.port))")
                            .font(.subheadline.monospaced())
                        Spacer()
                        Text(result.status)
                            .font(.subheadline)
                            .foregroundStyle(probeColor(result))
                    }
                    Text(result.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func probeColor(_ result: TunnelProbeResult) -> Color {
        switch result.outcome {
        case .connected: return LocusTheme.statusGood
        case .failed, .timedOut: return LocusTheme.statusWarn
        case .setupFailed: return LocusTheme.statusBad
        }
    }
}

struct PlacesView: View {
    @EnvironmentObject private var session: SpoofSession
    @EnvironmentObject private var pairing: PairingStore
    @Environment(\.dismiss) private var dismiss

    @State private var placeToRename: SavedPlace?
    @State private var renameText = ""

    var body: some View {
        NavigationStack {
            List {
                Section("Favorites") {
                    if session.favorites.isEmpty {
                        Text("Star a pin from the map to save it.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(session.favorites) { place in
                        placeButton(place)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    session.removeFavorite(place)
                                } label: {
                                    Label("Delete", systemImage: "trash.fill")
                                }
                                Button {
                                    placeToRename = place
                                    renameText = place.name
                                } label: {
                                    Label("Rename", systemImage: "pencil")
                                }
                                .tint(.gray)
                            }
                    }
                }

                Section("Recents") {
                    if session.recents.isEmpty {
                        Text("Teleports show up here.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(session.recents) { place in
                        placeButton(place)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    session.removeRecent(place)
                                } label: {
                                    Label("Delete", systemImage: "trash.fill")
                                }
                            }
                    }
                }
            }
            .navigationTitle("Places")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Rename Favorite", isPresented: Binding(
                get: { placeToRename != nil },
                set: { if !$0 { placeToRename = nil } }
            )) {
                TextField("Name", text: $renameText)
                Button("Cancel", role: .cancel) {
                    placeToRename = nil
                }
                Button("Save") {
                    if let place = placeToRename {
                        session.renameFavorite(place, to: renameText)
                    }
                    placeToRename = nil
                }
            } message: {
                Text("Choose a name you’ll recognize later.")
            }
        }
    }

    private func placeButton(_ place: SavedPlace) -> some View {
        Button {
            session.teleport(to: place.coordinate, pairing: pairing)
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(place.name).foregroundStyle(.primary)
                Text(String(format: "%.5f, %.5f", place.latitude, place.longitude))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }
}
