import SwiftUI

@main
struct HuntersMapApp: App {
    @StateObject private var store = AreaStore()
    @StateObject private var recorder = TrackRecorder()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(recorder)
        }
    }
}
