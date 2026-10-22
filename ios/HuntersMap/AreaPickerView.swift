import SwiftUI

// Searchable list of kanalintu areas. Picking one makes it the active hunting area.
// Pushed from the settings screen; `onDone` closes settings so the map shows the choice.
struct AreaPickerView: View {
    @EnvironmentObject private var store: AreaStore
    @State private var query = ""
    let onDone: () -> Void

    var body: some View {
        List(store.search(query)) { area in
            Button {
                store.selectedCode = area.code
                onDone()
            } label: {
                AreaRow(area: area, isSelected: area.code == store.selectedCode)
            }
            .foregroundStyle(.primary)
        }
        .listStyle(.plain)
        .overlay {
            if store.search(query).isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Nimi, numero, kunta tai maakunta")
        .navigationTitle("Kanalintualueet")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if store.selectedCode != nil {
                ToolbarItem(placement: .destructiveAction) {
                    Button("Poista valinta", role: .destructive) {
                        store.selectedCode = nil
                        onDone()
                    }
                }
            }
        }
    }
}

private struct AreaRow: View {
    let area: Area
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(area.name).font(.body.weight(.medium))
                Text(details)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            if isSelected {
                Image(systemName: "checkmark").foregroundStyle(.tint).fontWeight(.semibold)
            }
        }
        .contentShape(Rectangle())
    }

    private var details: String {
        var parts = [area.code]
        if let municipality = area.municipality { parts.append(municipality) }
        parts.append(contentsOf: area.regions)
        return parts.joined(separator: " · ")
    }
}
