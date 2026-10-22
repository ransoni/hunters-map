import SwiftUI

/// Hub for hunting groups (seurueet), opened from the top bar: sign in, list of groups,
/// create / join, and the account page.
struct GroupsView: View {
    @EnvironmentObject private var auth: AuthModel
    @EnvironmentObject private var sharing: SharingModel
    @Environment(\.dismiss) private var dismiss
    @State private var path: [String] = []
    @State private var creating = false
    @State private var newName = ""
    @State private var joining = false
    @State private var joinCode = ""

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if auth.isSignedIn {
                    signedIn
                } else {
                    SignInSection()
                }
                MapSettingsSection()
            }
            .navigationTitle("Seurueet")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: String.self) { GroupDetailView(groupID: $0) }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Sulje") { dismiss() }
                }
            }
            .refreshable { await sharing.reload() }
            .task { await sharing.reload() }
            .alert("Perusta seurue", isPresented: $creating) {
                TextField("Seurueen nimi", text: $newName)
                Button("Perusta") {
                    let name = newName
                    newName = ""
                    Task {
                        if let group = await sharing.createGroup(name: name) { path.append(group.id) }
                    }
                }
                Button("Peruuta", role: .cancel) { newName = "" }
            }
            .alert("Liity seurueeseen", isPresented: $joining) {
                TextField("Kutsukoodi", text: $joinCode)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                Button("Liity") {
                    let code = joinCode
                    joinCode = ""
                    Task {
                        if let group = await sharing.join(code: code) { path.append(group.id) }
                    }
                }
                Button("Peruuta", role: .cancel) { joinCode = "" }
            } message: {
                Text("Kysy 8-merkkinen koodi seurueen jäseneltä.")
            }
            .modifier(ErrorAlert(message: $sharing.errorMessage))
            .modifier(ErrorAlert(message: $auth.errorMessage))
            .overlay {
                if auth.isWorking { ProgressView().controlSize(.large) }
            }
        }
    }

    @ViewBuilder
    private var signedIn: some View {
        Section {
            if sharing.groups.isEmpty {
                Text("Et ole vielä missään seurueessa. Perusta oma tai liity kutsukoodilla.")
                    .foregroundStyle(.secondary)
            }
            ForEach(sharing.groups) { group in
                NavigationLink(value: group.id) { GroupRow(group: group) }
            }
        } header: {
            Text("Omat seurueet")
        }

        Section {
            Button("Perusta seurue", systemImage: "plus.circle") { creating = true }
            Button("Liity kutsukoodilla", systemImage: "ticket") { joining = true }
        }

        Section {
            NavigationLink {
                AccountView()
            } label: {
                Label(auth.profile?.displayName ?? "Tili", systemImage: "person.crop.circle")
            }
        }
    }
}

private struct GroupRow: View {
    @EnvironmentObject private var sharing: SharingModel
    let group: HuntingGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(group.name).font(.body.weight(.medium))
            if let until = sharing.sharingUntil(in: group.id) {
                Label("Jaat sijaintia klo \(until.formatted(date: .omitted, time: .shortened)) asti",
                      systemImage: "location.fill")
                    .font(.footnote)
                    .foregroundStyle(.green)
            } else {
                Text(group.role == "owner" ? "Omistaja" : "Jäsen")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Group page: sharing switch, members with live status, invite code, leave / delete.
struct GroupDetailView: View {
    @EnvironmentObject private var auth: AuthModel
    @EnvironmentObject private var sharing: SharingModel
    @Environment(\.dismiss) private var dismiss
    let groupID: String

    @State private var group: HuntingGroup?
    @State private var invite: GroupInvite?
    @State private var duration: TimeInterval = 8 * 3600
    @State private var busy = false
    @State private var confirmingLeave = false
    @State private var confirmingDelete = false

    private var isOwner: Bool { group?.ownerId == auth.user?.uid }

    var body: some View {
        List {
            if let group {
                sharingSection
                membersSection(group)
                inviteSection(group)
                dangerSection
            }
        }
        .navigationTitle(group?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if group == nil || busy { ProgressView() }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private var sharingSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { sharing.isSharing(in: groupID) },
                set: { on in
                    Task {
                        busy = true
                        await sharing.setSharing(groupID: groupID, duration: on ? duration : nil)
                        await load()
                        busy = false
                    }
                }
            )) {
                Label("Jaa sijaintini", systemImage: "location.fill")
            }
            if let until = sharing.sharingUntil(in: groupID) {
                LabeledContent("Jaetaan", value: "klo \(until.formatted(date: .omitted, time: .shortened)) asti")
                if let last = sharing.lastUpload {
                    LabeledContent("Viimeksi lähetetty") {
                        Text(last, style: .relative) + Text(" sitten")
                    }
                }
            } else {
                Picker("Kesto", selection: $duration) {
                    ForEach(SharingModel.durations, id: \.self) { d in
                        Text("\(Int(d / 3600)) h").tag(d)
                    }
                }
            }
        } header: {
            Text("Sijainnin jakaminen")
        } footer: {
            Text("Seurueen jäsenet näkevät sijaintisi kartalla. Jakaminen jatkuu näytön ollessa lukittuna ja loppuu automaattisesti.")
        }
    }

    private func membersSection(_ group: HuntingGroup) -> some View {
        Section("Jäsenet (\(group.members?.count ?? 0))") {
            ForEach(group.members ?? []) { member in
                MemberRow(
                    member: member,
                    isMe: member.userId == auth.user?.uid,
                    position: sharing.hunters.first { $0.id == member.userId })
            }
        }
    }

    private func inviteSection(_ group: HuntingGroup) -> some View {
        Section {
            if let invite {
                VStack(alignment: .leading, spacing: 6) {
                    Text(invite.code)
                        .font(.system(.largeTitle, design: .monospaced).weight(.bold))
                        .textSelection(.enabled)
                    Text("Voimassa \(invite.expiresAt.formatted(date: .abbreviated, time: .omitted)) asti")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ShareLink(item: "Liity seurueeseen \"\(group.name)\" Riistakartassa kutsukoodilla \(invite.code)") {
                    Label("Jaa kutsu", systemImage: "square.and.arrow.up")
                }
            } else {
                Button("Luo kutsukoodi", systemImage: "ticket") {
                    Task { invite = await sharing.invite(groupID: groupID) }
                }
            }
        } header: {
            Text("Kutsu metsästäjiä")
        }
    }

    private var dangerSection: some View {
        Section {
            Button("Poistu seurueesta", role: .destructive) { confirmingLeave = true }
                .confirmationDialog("Poistutaanko seurueesta?", isPresented: $confirmingLeave, titleVisibility: .visible) {
                    Button("Poistu", role: .destructive) {
                        Task { if await sharing.leave(groupID: groupID) { dismiss() } }
                    }
                } message: {
                    Text(isOwner ? "Omistajuus siirtyy pisimpään mukana olleelle jäsenelle." : "Voit liittyä uudelleen kutsukoodilla.")
                }
            if isOwner {
                Button("Poista seurue", role: .destructive) { confirmingDelete = true }
                    .confirmationDialog("Poistetaanko seurue kaikilta?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                        Button("Poista seurue", role: .destructive) {
                            Task { if await sharing.deleteGroup(groupID: groupID) { dismiss() } }
                        }
                    }
            }
        }
    }

    private func load() async {
        if let fresh = await sharing.detail(groupID: groupID) { group = fresh }
    }
}

private struct MemberRow: View {
    let member: GroupMember
    let isMe: Bool
    let position: HunterPosition?

    var body: some View {
        HStack(spacing: 12) {
            Text(HunterStyle.initials(member.displayName))
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color(HunterStyle.color(for: member.userId))))
            VStack(alignment: .leading, spacing: 2) {
                Text(member.displayName + (isMe ? " (sinä)" : ""))
                    + Text(member.role == "owner" ? "  ·  omistaja" : "").foregroundStyle(.secondary)
                status.font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        if let until = member.sharingUntil, until > .now {
            if let position, let still = position.stillMinutes() {
                Text("Jakaa · paikallaan \(still) min")
            } else if let position {
                Text("Jakaa · päivitetty ") + Text(position.updatedAt, style: .relative) + Text(" sitten")
            } else {
                Text("Jakaa sijaintia")
            }
        } else {
            Text("Ei jaa sijaintia")
        }
    }
}

/// Shows an error message from a model as an alert.
struct ErrorAlert: ViewModifier {
    @Binding var message: String?

    func body(content: Content) -> some View {
        content.alert("Virhe", isPresented: Binding(
            get: { message != nil },
            set: { if !$0 { message = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
    }
}
