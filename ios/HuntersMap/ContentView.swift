import SwiftUI
import CoreLocation
import MapLibre

struct ContentView: View {
    @EnvironmentObject private var store: AreaStore
    @EnvironmentObject private var recorder: TrackRecorder
    @EnvironmentObject private var auth: AuthModel
    @State private var showingAccount = false
    @State private var trackingMode: MLNUserTrackingMode = .none
    @State private var fitRequest = 0
    @State private var zoomStep: MapView.ZoomStep?
    @State private var showingPicker = false
    @State private var showingLocationDenied = false
    private let locationManager = CLLocationManager()

    var body: some View {
        MapView(areas: store.areas, selected: store.selected, trackingMode: $trackingMode,
                fitRequest: fitRequest, zoomStep: zoomStep, track: recorder.points)
            .ignoresSafeArea()
            .overlay(alignment: .top) { areaBar.padding(.horizontal) }
            .overlay(alignment: .bottomTrailing) {
                VStack(spacing: 16) {
                    recordButton
                    zoomButtons
                    locationButton
                }
                .padding()
            }
            .onChange(of: recorder.permissionDenied) { _, denied in
                if denied { showingLocationDenied = true }
            }
            .sheet(isPresented: $showingPicker) { AreaPickerView() }
            .sheet(isPresented: $showingAccount) { AccountView() }
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

    /// Active area: tap the name to fit the map to it, the list button to pick another.
    private var areaBar: some View {
        HStack(spacing: 0) {
            Button {
                if store.selected == nil { showingPicker = true } else { fitRequest += 1 }
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
            Button {
                showingAccount = true
            } label: {
                Image(systemName: auth.isSignedIn ? "person.crop.circle.fill" : "person.crop.circle")
                    .font(.title3.weight(.semibold))
                    .frame(width: 44, height: 50)
            }
            .accessibilityLabel("Tili")
            Button {
                showingPicker = true
            } label: {
                Image(systemName: "list.bullet")
                    .font(.title3.weight(.semibold))
                    .frame(width: 50, height: 50)
            }
            .accessibilityLabel("Valitse alue")
        }
        .foregroundStyle(.primary)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
    }

    /// Starts/stops recording the walked track (shown as a fading trail, also with the screen locked).
    private var recordButton: some View {
        Button {
            recorder.toggle()
        } label: {
            Image(systemName: "figure.walk")
                .font(.title2.weight(.medium))
                .foregroundStyle(recorder.isRecording ? .white : .primary)
                .frame(width: 54, height: 54)
                .background {
                    if recorder.isRecording {
                        Circle().fill(Color(MapView.trailColor))
                    } else {
                        Circle().fill(.regularMaterial)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if recorder.isRecording {
                        Circle().fill(.red).frame(width: 12, height: 12)
                            .overlay(Circle().stroke(.white, lineWidth: 2))
                    }
                }
                .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        }
        .accessibilityLabel(recorder.isRecording ? "Lopeta reitin tallennus" : "Tallenna reitti")
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
                .font(.title2.weight(.medium))
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
                .font(.title2.weight(.medium))
                .frame(width: 54, height: 54)
                .background(.regularMaterial, in: Circle())
                .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        }
        .accessibilityLabel("Oma sijainti")
        .padding(.bottom, 24)
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
