import SwiftUI

// Searchable list of kanalintu areas. Picking one makes it the active hunting area.
struct AreaPickerView: View {
    @EnvironmentObject private var store: AreaStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List(store.search(query)) { area in
                Button {
                    store.selectedCode = area.code
                    dismiss()
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
                ToolbarItem(placement: .cancellationAction) {
                    Button("Sulje") { dismiss() }
                }
                if store.selectedCode != nil {
                    ToolbarItem(placement: .destructiveAction) {
                        Button("Poista valinta", role: .destructive) {
                            store.selectedCode = nil
                            dismiss()
                        }
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
