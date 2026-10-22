import SwiftUI
import GoogleSignInSwift

// Sign in / profile sheet. Signing in is only needed for sharing the location with a
// hunting party; the map, areas and track work without an account.
struct AccountView: View {
    @EnvironmentObject private var auth: AuthModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var name = ""
    @State private var confirmingDelete = false

    var body: some View {
        NavigationStack {
            Form {
                if auth.isSignedIn {
                    signedIn
                } else {
                    signedOut
                }
            }
            .navigationTitle("Tili")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Sulje") { dismiss() }
                }
            }
            .disabled(auth.isWorking)
            .overlay {
                if auth.isWorking { ProgressView().controlSize(.large) }
            }
            .alert("Virhe", isPresented: Binding(
                get: { auth.errorMessage != nil },
                set: { if !$0 { auth.errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(auth.errorMessage ?? "")
            }
        }
    }

    private var signedOut: some View {
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
