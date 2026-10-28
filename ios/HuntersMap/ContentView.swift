import SwiftUI
import CoreLocation
import MapLibre

struct ContentView: View {
    @EnvironmentObject private var store: AreaStore
    @EnvironmentObject private var recorder: TrackRecorder
    @EnvironmentObject private var auth: AuthModel
    @EnvironmentObject private var sharing: SharingModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingSettings = false
    @State private var settingsStart: SettingsRoute?
    @State private var togglingSharing = false
    @AppStorage(TrailSettings.recentMinutesKey) private var recentTrailMinutes = TrailSettings.defaultRecentMinutes
    @AppStorage(BaseLayer.storageKey) private var baseLayer = BaseLayer.topo
    @AppStorage(LeadShotBan.storageKey) private var showLeadShotBan = false
    @State private var trackingMode: MLNUserTrackingMode = .none
    @State private var fitRequest = 0
    @State private var zoomStep: MapView.ZoomStep?
    @State private var showingLocationDenied = false
    private let locationManager = CLLocationManager()

    var body: some View {
        MapView(areas: store.areas, selected: store.selected, trackingMode: $trackingMode,
                fitRequest: fitRequest, zoomStep: zoomStep, track: recorder.points, hunters: sharing.hunters, hunterTrails: sharing.trails,
                recentTrailMinutes: recentTrailMinutes, baseLayer: baseLayer, showLeadShotBan: showLeadShotBan)
            .ignoresSafeArea()
            .overlay(alignment: .top) { areaBar.padding(.horizontal) }
            .overlay(alignment: .bottomTrailing) {
                VStack(spacing: 16) {
                    zoomButtons
                    locationAndLayers
                }
                .padding()
            }
            .onChange(of: recorder.permissionDenied) { _, denied in
                if denied { showingLocationDenied = true }
            }
            .sheet(isPresented: $showingSettings) { SettingsView(start: settingsStart) }
            .onChange(of: auth.user?.uid, initial: true) { _, uid in sharing.userChanged(uid) }
            .onChange(of: scenePhase) { _, phase in
                // Sharing may have ended (or been changed elsewhere) while in the background.
                if phase == .active { Task { await sharing.reload() } }
            }
            .alert("Sijainti ei ole käytössä", isPresented: $showingLocationDenied) {
                Button("Asetukset") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                Button("OK", role: .cancel) {}
            } message: {
                Text("Salli sijainti Riistakartalle asetuksista, niin oma paikkasi näkyy kartalla.")
            }
    }

    /// Active area (tap: fit the map to it), the sharing switch and the settings gear.
    private var areaBar: some View {
        HStack(spacing: 0) {
            Button {
                if store.selected == nil { openSettings(.areas) } else { fitRequest += 1 }
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    if let area = store.selected {
                        Text(area.name).font(.headline)
                        Text(subtitle(for: area)).font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Valitse kanalintualue").font(.headline)
                        Text("Ei aktiivista aluetta").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 10)
                .padding(.leading, 14)
                .contentShape(Rectangle())
            }
            if sharing.canToggleSharing {
                sharingSwitch
            }
            Button {
                openSettings(nil)
            } label: {
                Image(systemName: "gearshape")
                    .font(.title3.weight(.regular))
                    .frame(width: 50, height: 50)
            }
            .accessibilityLabel("Asetukset")
        }
        .foregroundStyle(.primary)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
    }

    /// Green with signal waves while sharing; tap stops sharing in all groups (red, no waves).
    /// Tapping red resumes in the groups last shared with, or opens settings to pick a group.
    private var sharingSwitch: some View {
        Button {
            togglingSharing = true
            Task {
                if sharing.isSharing {
                    await sharing.stopAllSharing()
                } else if await !sharing.resumeSharing() {
                    openSettings(nil)
                }
                togglingSharing = false
            }
        } label: {
            Image(systemName: sharing.isSharing ? "person.2.wave.2.fill" : "person.2.fill")
                .font(.title3.weight(.regular))
                .foregroundStyle(sharing.isSharing ? Color.green : Color.red)
                .frame(width: 44, height: 50)
                .opacity(togglingSharing ? 0.4 : 1)
        }
        .disabled(togglingSharing)
        .accessibilityLabel(sharing.isSharing ? "Jaat sijaintia, lopeta jakaminen" : "Et jaa sijaintia, jatka jakamista")
    }

    private func openSettings(_ start: SettingsRoute?) {
        settingsStart = start
        showingSettings = true
    }

    /// Second control group: base map choice above the location button.
    private var locationAndLayers: some View {
        VStack(spacing: 0) {
            layerButton
            Divider().frame(width: 34)
            locationButton
        }
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        .padding(.bottom, 24)
    }

    /// Base map choice: vector or raster topo map or orthophotos (the last two need the MML
    /// key), and the lead shot ban area overlay.
    private var layerButton: some View {
        Menu {
            ForEach(BaseLayer.allCases) { layer in
                // Toggle items show a checkmark next to the icon for the current choice.
                Toggle(isOn: Binding(
                    get: { BaseMap.effective(baseLayer) == layer },
                    set: { if $0 { baseLayer = layer } }
                )) {
                    Label {
                        Text(layer.title)
                    } icon: {
                        Image(uiImage: MapIcons.icon(for: layer))
                    }
                }
                .disabled(!BaseMap.isAvailable(layer))
            }
            Section {
                Toggle(isOn: $showLeadShotBan) {
                    Label("Lyijyhaulikielto", systemImage: "drop.triangle")
                }
            }
        } label: {
            Image(systemName: "square.3.layers.3d")
                .font(.title2.weight(.light))
                .frame(width: 54, height: 54)
                .contentShape(Rectangle())
        }
        .foregroundStyle(.primary)
        .accessibilityLabel("Karttataso")
    }

    /// Big +/− buttons: easier than pinching with gloves or one hand.
    private var zoomButtons: some View {
        VStack(spacing: 0) {
            zoomButton("plus", delta: 1, label: "Lähennä")
            Divider().frame(width: 34)
            zoomButton("minus", delta: -1, label: "Loitonna")
        }
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
    }

    private func zoomButton(_ icon: String, delta: Double, label: String) -> some View {
        Button {
            zoomStep = MapView.ZoomStep(id: (zoomStep?.id ?? 0) + 1, delta: delta)
        } label: {
            Image(systemName: icon)
                .font(.title2.weight(.light))
                .frame(width: 54, height: 54)
                .contentShape(Rectangle())
        }
        .foregroundStyle(.primary)
        .accessibilityLabel(label)
    }

    /// Off -> follow -> follow with heading -> off.
    private var locationButton: some View {
        Button {
            switch locationManager.authorizationStatus {
            case .denied, .restricted:
                showingLocationDenied = true
                return
            case .notDetermined:
                locationManager.requestWhenInUseAuthorization()
            default:
                break
            }
            switch trackingMode {
            case .none: trackingMode = .follow
            case .follow: trackingMode = .followWithHeading
            default: trackingMode = .none
            }
        } label: {
            Image(systemName: locationIcon)
                .font(.title2.weight(.light))
                .frame(width: 54, height: 54)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Oma sijainti")
    }

    private var locationIcon: String {
        switch trackingMode {
        case .follow: "location.fill"
        case .followWithHeading, .followWithCourse: "location.north.line.fill"
        default: "location"
        }
    }

    private func subtitle(for area: Area) -> String {
        var parts = [area.code]
        if let municipality = area.municipality { parts.append(municipality) }
        if let ha = area.areaHa { parts.append("\(Int(ha).formatted()) ha") }
        return parts.joined(separator: " · ")
    }
}
