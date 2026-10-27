import Foundation
import MapLibre

// Base map layers under the hunting areas and trails.
//
// With a Maanmittauslaitos API key (MML_API_KEY, see ios/Config.xcconfig) the topo map is
// MML's vector topo map (the "hobby" style of their v21 vector tiles, with contours, terrain
// and POIs) and the orthophoto layer is available; without one the topo map is OpenTopoMap
// raster tiles and orthophotos can't be chosen.
//
// MMLAuth adds the key as HTTP Basic auth (key as user name, empty password, as MML documents)
// to requests for MML's host only. MML's style JSON then carries it in its own tile and glyph
// URLs, which is how MML intends client apps to use it.

enum BaseLayer: String, CaseIterable, Identifiable {
    case topo
    case ortho

    var id: String { rawValue }

    var title: String {
        switch self {
        case .topo: "Maastokartta"
        case .ortho: "Ortokuva"
        }
    }

    static let storageKey = "baseLayer"
}

struct RasterSourceSpec {
    let id: String
    let tiles: [String]
    let maxZoom: Double
    let attribution: String
}

enum BaseMap {
    static let mmlHost = "avoin-karttakuva.maanmittauslaitos.fi"

    /// MML API key from the Info.plist, nil when not configured.
    static let mmlKey: String? = {
        let key = (Bundle.main.object(forInfoDictionaryKey: "MMLAPIKey") as? String)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return key.isEmpty || key.hasPrefix("$(") ? nil : key
    }()

    static var orthoAvailable: Bool { mmlKey != nil }

    /// The layer actually shown: orthophotos fall back to the topo map without a key.
    static func effective(_ layer: BaseLayer) -> BaseLayer {
        layer == .ortho && !orthoAvailable ? .topo : layer
    }

    /// The map style: MML's vector topo map with a key, else the bundled style that gets
    /// OpenTopoMap (rasterTopo) added under everything.
    static var styleURL: URL? {
        guard mmlKey != nil else { return Bundle.main.url(forResource: "TopoStyle", withExtension: "json") }
        return URL(string: "https://\(mmlHost)/vectortiles/stylejson/v21/hobby.json?TileMatrixSet=WGS84_Pseudo-Mercator")
    }

    /// Font for our own labels; it must exist in the style's glyph set.
    static var labelFonts: [String] { mmlKey != nil ? ["Liberation Sans NLSFI Bold"] : ["Open Sans Semibold"] }

    /// Raster topo map used when there is no MML key.
    static var rasterTopo: RasterSourceSpec? {
        guard mmlKey == nil else { return nil }
        return RasterSourceSpec(
            id: "base-topo",
            tiles: ["a", "b", "c"].map { "https://\($0).tile.opentopomap.org/{z}/{x}/{y}.png" },
            maxZoom: 17,
            attribution: "Kartta: © OpenTopoMap (CC-BY-SA), © OpenStreetMap-tekijät, SRTM")
    }

    static var ortho: RasterSourceSpec? {
        guard mmlKey != nil else { return nil }
        return RasterSourceSpec(
            id: "base-ortho",
            tiles: ["https://\(mmlHost)/avoin/wmts/1.0.0/ortokuva/default/WGS84_Pseudo-Mercator/{z}/{y}/{x}.jpg"],
            maxZoom: 18,
            attribution: "Ortokuva: © Maanmittauslaitos (CC BY 4.0)")
    }
}

/// Adds the MML API key to MapLibre's requests for MML's host.
final class MMLAuth: NSObject, MLNNetworkConfigurationDelegate {
    private static let shared = MMLAuth()
    private let header: String?

    private override init() {
        header = BaseMap.mmlKey.map { "Basic " + Data("\($0):".utf8).base64EncodedString() }
    }

    /// Call before the first map view is created.
    static func install() {
        MLNNetworkConfiguration.sharedManager.delegate = shared
    }

    func willSend(_ request: NSMutableURLRequest) -> NSMutableURLRequest {
        if let header, request.url?.host == BaseMap.mmlHost {
            request.setValue(header, forHTTPHeaderField: "Authorization")
        }
        return request
    }
}

/// Lead shot ban areas (lyijyhaulikieltoalueet): wetlands and their 100 m buffer zones where
/// lead shot may not be used or carried (EU 2021/57). Drawn as a red crosshatch over the base
/// map from Syke's WMS, the same data as Tukes' Suomi.fi map and Oma riista.
///
/// The WMS only draws between 1:1 000 and 1:100 000. Tiles are requested at 512 px so GeoServer
/// sees half the scale of a 256 px tile: zoom 12 lands at about 1:68 000 and is drawn, and the
/// lines stay sharp on retina screens.
enum LeadShotBan {
    static let storageKey = "leadShotBanAreas"
    static let minZoom = 12.0

    static let source = RasterSourceSpec(
        id: "lead-shot-ban",
        tiles: ["https://paikkatiedot.ymparisto.fi/geoserver/lyijyhaulikieltoalueet/wms?service=WMS&version=1.1.1&request=GetMap&layers=lyijyhaulikieltoalueet&styles=&srs=EPSG:3857&bbox={bbox-epsg-3857}&width=512&height=512&format=image/png&transparent=true"],
        maxZoom: 18,
        attribution: "Lyijyhaulikieltoalueet: © Syke, Tukes")
}
