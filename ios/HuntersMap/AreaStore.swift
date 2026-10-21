import Foundation
import CoreLocation

// Pienriista-alueet from the web app's data (scripts/build_web_data.py), copied into
// the app bundle by the "Copy area data" build phase:
//   areas.json     area list: details, regions, area_ha, kanalintu quotas, bbox, label
//   areas.geojson  simplified boundaries (code, name), drawn by MapView

struct Area: Decodable, Identifiable, Hashable {
    let code: String
    let name: String
    let municipality: String?
    let regions: [String]
    let areaHa: Double?
    let kanalintu: Kanalintu?
    let bbox: [Double] // [west, south, east, north]
    let label: [Double] // [lon, lat]
    let retkikarttaUrl: String?

    var id: String { code }

    var labelCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: label[1], longitude: label[0])
    }

    struct Kanalintu: Decodable, Hashable {
        let year: Int
        let phase1Days: Int?
        let phase2Days: Int?
    }

    enum CodingKeys: String, CodingKey {
        case code, name, municipality, regions, kanalintu, bbox, label
        case areaHa = "area_ha"
        case retkikarttaUrl = "retkikartta_url"
    }
}

extension Area.Kanalintu {
    enum CodingKeys: String, CodingKey {
        case year
        case phase1Days = "phase1_days"
        case phase2Days = "phase2_days"
    }
}

@MainActor
final class AreaStore: ObservableObject {
    /// Kanalintu areas, i.e. those with day-permit quotas, sorted by name.
    @Published private(set) var areas: [Area] = []
    @Published var selectedCode: String? {
        didSet { UserDefaults.standard.set(selectedCode, forKey: Self.selectedKey) }
    }

    private static let selectedKey = "selectedAreaCode"
    private static let finnish = Locale(identifier: "fi_FI")

    var selected: Area? { areas.first { $0.code == selectedCode } }

    init() {
        selectedCode = UserDefaults.standard.string(forKey: Self.selectedKey)
        do {
            let url = Bundle.main.url(forResource: "areas", withExtension: "json")!
            let all = try JSONDecoder().decode([Area].self, from: Data(contentsOf: url))
            areas = all
                .filter { $0.kanalintu != nil }
                // Finnish collation regardless of the phone's language: Ä and Ö after Z.
                .sorted { $0.name.compare($1.name, options: [.caseInsensitive, .numeric], locale: Self.finnish) == .orderedAscending }
        } catch {
            assertionFailure("areas.json: \(error)")
        }
    }

    /// Matches name, number, municipality or maakunta, like the web app's search.
    func search(_ text: String) -> [Area] {
        let query = text.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return areas }
        return areas.filter { area in
            ([area.name, area.code, area.municipality ?? ""] + area.regions)
                .contains { $0.localizedStandardContains(query) }
        }
    }
}
