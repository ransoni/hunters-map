import SwiftUI
import FirebaseCore
import GoogleSignIn

@main
struct HuntersMapApp: App {
    @StateObject private var store = AreaStore()
    @StateObject private var recorder: TrackRecorder
    @StateObject private var auth: AuthModel
    @StateObject private var sharing: SharingModel

    init() {
        // Reads GoogleService-Info.plist (make ios-config); must run before AuthModel.
        FirebaseApp.configure()
        let recorder = TrackRecorder() // also the GPS engine for sharing
        _recorder = StateObject(wrappedValue: recorder)
        _auth = StateObject(wrappedValue: AuthModel())
        _sharing = StateObject(wrappedValue: SharingModel(recorder: recorder))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(recorder)
                .environmentObject(auth)
                .environmentObject(sharing)
                .onOpenURL { url in
                    // Google sign-in returns here through the REVERSED_CLIENT_ID URL scheme.
                    GIDSignIn.sharedInstance.handle(url)
                }
        }
    }
}
