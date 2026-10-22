import SwiftUI
import GoogleSignInSwift

/// Sign-in prompt, shown in the groups hub while signed out. Signing in is only needed for
/// sharing; the map, areas and track work without an account.
struct SignInSection: View {
    @EnvironmentObject private var auth: AuthModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Label("Jaa sijaintisi seurueen kanssa", systemImage: "person.2.wave.2")
                    .font(.headline)
                Text("Kirjautumalla voit perustaa seurueen, kutsua muita metsästäjiä ja nähdä toistenne sijainnit kartalla. Kartta ja reitin tallennus toimivat myös ilman tiliä.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)

            GoogleSignInButton(scheme: colorScheme == .dark ? .dark : .light, style: .wide) {
                Task { await auth.signInWithGoogle() }
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        }
    }
}

/// Profile: display name, sign out, delete account. Pushed from GroupsView.
struct AccountView: View {
    @EnvironmentObject private var auth: AuthModel
    @State private var name = ""
    @State private var confirmingDelete = false

    var body: some View {
        Form {
            if auth.isSignedIn {
                signedIn
            } else {
                SignInSection()
            }
        }
        .navigationTitle("Tili")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(auth.isWorking)
    }

    @ViewBuilder
    private var signedIn: some View {
        Section("Nimi muille metsästäjille") {
            HStack {
                TextField("Nimi", text: $name)
                    .textContentType(.name)
                    .submitLabel(.done)
                    .onSubmit(saveName)
                if nameChanged {
                    Button("Tallenna", action: saveName)
                }
            }
        }
        .onAppear { name = auth.profile?.displayName ?? "" }
        .onChange(of: auth.profile?.displayName) { _, new in name = new ?? "" }

        Section("Kirjautunut") {
            Text(auth.profile?.email ?? auth.user?.email ?? "")
                .foregroundStyle(.secondary)
            Button("Kirjaudu ulos") { auth.signOut() }
        }

        Section {
            Button("Poista tili", role: .destructive) { confirmingDelete = true }
                .confirmationDialog("Poistetaanko tili?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                    Button("Poista tili ja tiedot", role: .destructive) {
                        Task { await auth.deleteAccount() }
                    }
                } message: {
                    Text("Sinut poistetaan kaikista seurueista ja jaetut sijaintisi poistetaan. Tätä ei voi perua.")
                }
        } footer: {
            Text("Poistaa profiilin, seurueiden jäsenyydet ja jaetut sijainnit palvelimelta.")
        }
    }

    private var nameChanged: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && trimmed != auth.profile?.displayName
    }

    private func saveName() {
        guard nameChanged else { return }
        Task { await auth.updateDisplayName(name) }
    }
}
