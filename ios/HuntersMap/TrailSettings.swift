import SwiftUI

/// User setting: how many of the latest minutes of a trail are drawn in colour before it turns
/// into the grey dashed line (which continues up to TrackRecorder.window). Stored per phone.
enum TrailSettings {
    static let recentMinutesKey = "recentTrailMinutes"
    static let defaultRecentMinutes = 15
    static let options = [5, 10, 15, 30]
}

/// "Kartta" section of the hub: trail settings.
struct MapSettingsSection: View {
    @AppStorage(TrailSettings.recentMinutesKey) private var recentMinutes = TrailSettings.defaultRecentMinutes

    var body: some View {
        Section {
            Picker("Värillinen jälki", selection: $recentMinutes) {
                ForEach(TrailSettings.options, id: \.self) { minutes in
                    Text("\(minutes) min").tag(minutes)
                }
            }
        } header: {
            Text("Kartta")
        } footer: {
            Text("Näin pitkä osa kuljetusta reitistä näytetään värillisenä. Vanhempi osa näkyy harmaana katkoviivana tunnin ajan, joten pysähtyminen erottuu kartalla.")
        }
    }
}
