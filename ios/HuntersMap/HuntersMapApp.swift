import SwiftUI
import FirebaseCore
import GoogleSignIn

@main
struct HuntersMapApp: App {
    @StateObject private var store = AreaStore()
    @StateObject private var recorder = TrackRecorder()
    @StateObject private var auth: AuthModel

    init() {
        // Reads GoogleService-Info.plist (make ios-config); must run before AuthModel.
        FirebaseApp.configure()
        _auth = StateObject(wrappedValue: AuthModel())
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(recorder)
                .environmentObject(auth)
                .onOpenURL { url in
                    // Google sign-in returns here through the REVERSED_CLIENT_ID URL scheme.
                    GIDSignIn.sharedInstance.handle(url)
                }
        }
    }
}
