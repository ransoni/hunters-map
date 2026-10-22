import Foundation
import UIKit
import FirebaseAuth
import FirebaseCore
import GoogleSignIn

// Sign-in state. Google sign-in gives a Google ID token, which is exchanged for a Firebase
// session (kept across launches by Firebase); the backend then knows the user by that
// session's ID token. The map works without signing in; sharing needs an account.

@MainActor
final class AuthModel: ObservableObject {
    @Published private(set) var user: User?
    @Published private(set) var profile: Profile?
    @Published private(set) var isWorking = false
    @Published var errorMessage: String?

    private let api: APIClient
    private var listener: AuthStateDidChangeListenerHandle?

    var isSignedIn: Bool { user != nil }

    init(api: APIClient = .shared) {
        self.api = api
        if let clientID = FirebaseApp.app()?.options.clientID {
            GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
        }
        listener = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in self?.userChanged(user) }
        }
    }

    func signInWithGoogle() async {
        guard let presenter = Self.topViewController() else { return }
        await run {
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenter)
            guard let idToken = result.user.idToken?.tokenString else { throw APIError.badResponse }
            let credential = GoogleAuthProvider.credential(
                withIDToken: idToken, accessToken: result.user.accessToken.tokenString)
            try await Auth.auth().signIn(with: credential)
            self.profile = try await self.api.me()
        }
    }

    func signOut() {
        GIDSignIn.sharedInstance.signOut()
        do {
            try Auth.auth().signOut()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateDisplayName(_ name: String) async {
        await run { self.profile = try await self.api.updateProfile(displayName: name) }
    }

    /// Deletes the account on the server (groups, positions, sign-in account) and signs out.
    func deleteAccount() async {
        await run {
            try await self.api.deleteAccount()
            self.signOut()
        }
    }

    func refreshProfile() async {
        guard isSignedIn else { return }
        await run { self.profile = try await self.api.me() }
    }

    // MARK: Private

    private func userChanged(_ user: User?) {
        self.user = user
        if user == nil {
            profile = nil
        } else if profile == nil && !isWorking { // signInWithGoogle loads it itself
            Task { await refreshProfile() }
        }
    }

    private func run(_ work: @escaping () async throws -> Void) async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await work()
        } catch let error as GIDSignInError where error.code == .canceled {
            // User closed the Google sheet.
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Google sign-in presents its sheet on top of whatever is showing (e.g. our account sheet).
    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        var top = scene?.keyWindow?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}
