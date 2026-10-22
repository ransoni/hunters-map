import SwiftUI

/// User setting: how many of the latest minutes of a trail are drawn in colour before it turns
/// into the grey dashed line (which continues up to TrackRecorder.window). Stored per phone.
enum TrailSettings {
    static let recentMinutesKey = "recentTrailMinutes"
    static let defaultRecentMinutes = 15
    static let options = [5, 10, 15, 30]
}

/// "Kartta" section of the settings: own route recording and trail length.
struct MapSettingsSection: View {
    @EnvironmentObject private var recorder: TrackRecorder
    @AppStorage(TrailSettings.recentMinutesKey) private var recentMinutes = TrailSettings.defaultRecentMinutes

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { recorder.isRecording }, set: { _ in recorder.toggle() })) {
                Label("Tallenna oma reitti", systemImage: "figure.walk")
            }
            Picker("Värillinen jälki", selection: $recentMinutes) {
                ForEach(TrailSettings.options, id: \.self) { minutes in
                    Text("\(minutes) min").tag(minutes)
                }
            }
        } header: {
            Text("Kartta")
        } footer: {
            Text("Oma reitti tallentuu myös näytön ollessa lukittuna, ja aina kun jaat sijaintiasi. Värillisen jäljen pituus koskee omaa ja muiden reittejä; vanhempi osa näkyy harmaana katkoviivana tunnin ajan, joten pysähtyminen erottuu kartalla.")
        }
    }
}
