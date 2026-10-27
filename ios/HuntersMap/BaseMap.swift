import MapLibre
import UIKit

// Base map layers under the hunting areas and trails.
//
// With a Maanmittauslaitos API key (MML_API_KEY, see ios/Config.xcconfig) the topo map is
// MML's vector topo map (the "hobby" style of their v21 vector tiles, with contours, terrain
// and POIs), and MML's classic raster maastokartta and orthophotos can be chosen too; without
// one the topo map is OpenTopoMap raster tiles and the MML-only layers can't be chosen.
//
// MMLAuth adds the key as HTTP Basic auth (key as user name, empty password, as MML documents)
// to requests for MML's host only. MML's style JSON then carries it in its own tile and glyph
// URLs, which is how MML intends client apps to use it.

enum BaseLayer: String, CaseIterable, Identifiable {
    case topo
    case topoRaster
    case ortho

    var id: String { rawValue }

    var title: String {
        switch self {
        case .topo: "Maastokartta"
        case .topoRaster: "Rasterikartta"
        case .ortho: "Ortokuva"
        }
    }

    /// Only available with an MML API key.
    var needsMMLKey: Bool { self != .topo }

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

    static func isAvailable(_ layer: BaseLayer) -> Bool { !layer.needsMMLKey || mmlKey != nil }

    /// The layer actually shown: MML-only layers fall back to the topo map without a key.
    static func effective(_ layer: BaseLayer) -> BaseLayer {
        isAvailable(layer) ? layer : .topo
    }

    /// Raster tile layers added over the style's own layers, and the choice each one shows.
    static var rasterLayers: [(BaseLayer, RasterSourceSpec)] {
        guard mmlKey != nil else { return [(.topo, openTopoMap)] }
        return [(.topoRaster, mmlRaster("maastokartta", format: "png", id: "base-topo-raster",
                                        attribution: "Maastokartta: © Maanmittauslaitos (CC BY 4.0)")),
                (.ortho, mmlRaster("ortokuva", format: "jpg", id: "base-ortho",
                                   attribution: "Ortokuva: © Maanmittauslaitos (CC BY 4.0)"))]
    }

    /// The map style: MML's vector topo map with a key, else the bundled style that gets
    /// OpenTopoMap (rasterLayers) added over its background.
    static var styleURL: URL? {
        guard mmlKey != nil else { return Bundle.main.url(forResource: "TopoStyle", withExtension: "json") }
        return URL(string: "https://\(mmlHost)/vectortiles/stylejson/v21/hobby.json?TileMatrixSet=WGS84_Pseudo-Mercator")
    }

    /// Font for our own labels; it must exist in the style's glyph set.
    static var labelFonts: [String] { mmlKey != nil ? ["Liberation Sans NLSFI Bold"] : ["Open Sans Semibold"] }

    /// Raster topo map used when there is no MML key.
    private static let openTopoMap = RasterSourceSpec(
        id: "base-topo",
        tiles: ["a", "b", "c"].map { "https://\($0).tile.opentopomap.org/{z}/{x}/{y}.png" },
        maxZoom: 17,
        attribution: "Kartta: © OpenTopoMap (CC-BY-SA), © OpenStreetMap-tekijät, SRTM")

    /// MML's open WMTS; both layers serve tiles up to zoom 18.
    private static func mmlRaster(_ layer: String, format: String, id: String, attribution: String) -> RasterSourceSpec {
        RasterSourceSpec(
            id: id,
            tiles: ["https://\(mmlHost)/avoin/wmts/1.0.0/\(layer)/default/WGS84_Pseudo-Mercator/{z}/{y}/{x}.\(format)"],
            maxZoom: 18,
            attribution: attribution)
    }
}

/// Adjustments to MML's vector style for use in the field: stronger contour lines, wider
/// ditches and small streams, readable cliff tick marks, larger place names, and clearcuts,
/// fields and open water drawn like on the raster maastokartta hunters are used to (green
/// hatching, yellow, and bright cyan with a blue shoreline). Applied when the style has loaded, by layer id and source layer,
/// so a missing layer (a style update at MML) is simply skipped.
enum VectorStyleTweaks {
    /// Darker than MML's light orange (252, 179, 110), so contours read in daylight.
    static let contourColor = UIColor(red: 0xD9 / 255, green: 0x7A / 255, blue: 0x2E / 255, alpha: 1)
    /// Line widths by zoom, by MML layer id: regular 2.5 m contours, 20 m / main index
    /// contours, and streams under 2 m wide, which include the drainage ditches on bogs.
    static let lineWidths: [String: [Double: Double]] = [
        "korkeus_viiva": [11: 0.8, 14: 1.3, 17: 1.8],
        "korkeus_paaviiva2": [11: 1.4, 14: 2.2, 17: 3],
        "korkeus_paaviiva": [13: 2.2, 17: 3.2],
        "vesisto_viiva_kapea": [11: 1, 13: 2, 15: 3, 17: 4.5],
        "maasto_viiva_jyrkanne": [12: 1.2, 14: 2.5, 16: 4.5, 18: 7],
        // The cliff's tick marks: a dashed line beside the cliff whose width is the tick length.
        cliffTicks: [14: 6, 16: 11, 18: 18],
    ]
    /// Cliff tick marks (jyrkänteen pykälät). MML draws them as dashes a tenth of the line width
    /// thick and as long as the cliff line is wide, which is too fine to see. The raster map's
    /// ticks are about a fifth as thick as they are long and 1.5 tick lengths apart, on a cliff
    /// line about 40 % of the tick length wide. Dash lengths are in multiples of the tick length.
    static let cliffTicks = "maasto_viiva_jyrkanne_pykala"
    static let cliffTickDashes: [Double] = [0.2, 1.3]
    /// Place name text size multiplier by zoom. MML's names stop growing at zoom 14–16 while a
    /// raster map's lettering keeps growing as it is magnified, so the factor grows with zoom to
    /// keep names about as large as on the raster maastokartta.
    static let placeNameScale: [(zoom: Double, factor: Double)] = [(10, 1.25), (14, 1.6), (16, 2.2), (18, 2.8)]

    /// MTK feature classes (kohdeluokka): open forest land, i.e. clearcuts and seedling stands,
    /// and cultivated fields.
    static let clearcutClass = 39110
    static let fieldClass = 32611
    /// The raster map's colours: yellow-green clearcut hatching and orange-yellow fields.
    static let clearcutHatchColor = UIColor(red: 195 / 255, green: 220 / 255, blue: 0, alpha: 1)
    static let fieldColor = UIColor(red: 1, green: 222 / 255, blue: 145 / 255, alpha: 1)
    static let fieldOutlineColor = UIColor(white: 0.2, alpha: 1)
    /// The raster map's open water: bright cyan with a blue shoreline, instead of MML's pale blue.
    static let waterColor = UIColor(red: 142 / 255, green: 253 / 255, blue: 1, alpha: 1)
    static let shorelineColor = UIColor(red: 0, green: 150 / 255, blue: 1, alpha: 1)

    static func apply(to style: MLNStyle) {
        var terrainFill: MLNFillStyleLayer?
        var landUseFill: MLNFillStyleLayer?
        var waterFill: MLNFillStyleLayer?
        for layer in style.layers {
            if let fill = layer as? MLNFillStyleLayer {
                if fill.sourceLayerIdentifier == "vesisto_alue" {
                    fill.fillColor = NSExpression(forConstantValue: waterColor)
                    waterFill = fill
                }
                // Clearcuts lose MML's yellow (it reads as a field); the hatching below replaces it.
                if fill.sourceLayerIdentifier == "maasto_alue", let color = fill.fillColor {
                    fill.fillColor = NSExpression(mglJSONObject: replacingMatchOutput(
                        color.mgl_jsonExpressionObject, for: clearcutClass, with: "rgba(0, 0, 0, 0)"))
                    terrainFill = fill
                } else if fill.sourceLayerIdentifier == "maankaytto", let color = fill.fillColor {
                    fill.fillColor = NSExpression(mglJSONObject: replacingMatchOutput(
                        color.mgl_jsonExpressionObject, for: fieldClass, with: hex(fieldColor)))
                    landUseFill = fill
                }
            } else if let line = layer as? MLNLineStyleLayer {
                if line.sourceLayerIdentifier == "korkeus" {
                    line.lineColor = NSExpression(forConstantValue: contourColor)
                }
                if let stops = lineWidths[line.identifier] {
                    line.lineWidth = zoomRamp(stops)
                    if line.identifier == cliffTicks {
                        // Shifted by half its width, so the ticks start at the cliff line.
                        line.lineOffset = zoomRamp(stops.mapValues { $0 / 2 })
                        line.lineDashPattern = NSExpression(forConstantValue: cliffTickDashes)
                    }
                }
            } else if let symbol = layer as? MLNSymbolStyleLayer, symbol.sourceLayerIdentifier == "nimisto",
                      let size = symbol.textFontSize {
                symbol.textFontSize = NSExpression(
                    mglJSONObject: scaledByZoom(size.mgl_jsonExpressionObject))
            }
        }
        if let terrainFill, let source = terrainFill.sourceIdentifier.flatMap(style.source(withIdentifier:)) {
            style.setImage(clearcutHatch, forName: "clearcut-hatch")
            let hatch = MLNFillStyleLayer(identifier: "clearcut-hatch", source: source)
            hatch.sourceLayerIdentifier = "maasto_alue"
            hatch.predicate = NSPredicate(format: "kohdeluokka == %d", clearcutClass)
            hatch.fillPattern = NSExpression(forConstantValue: "clearcut-hatch")
            style.insertLayer(hatch, above: landUseFill ?? terrainFill)
        }
        if let landUseFill, let source = landUseFill.sourceIdentifier.flatMap(style.source(withIdentifier:)) {
            let outline = MLNLineStyleLayer(identifier: "field-outline", source: source)
            outline.sourceLayerIdentifier = "maankaytto"
            outline.predicate = NSPredicate(format: "kohdeluokka == %d", fieldClass)
            outline.minimumZoomLevel = 12
            outline.lineColor = NSExpression(forConstantValue: fieldOutlineColor)
            outline.lineWidth = zoomRamp([12: 0.4, 15: 0.9, 17: 1.4])
            style.insertLayer(outline, above: style.layer(withIdentifier: "clearcut-hatch") ?? landUseFill)
        }
        if let waterFill, let source = waterFill.sourceIdentifier.flatMap(style.source(withIdentifier:)) {
            let shoreline = MLNLineStyleLayer(identifier: "shoreline", source: source)
            shoreline.sourceLayerIdentifier = "vesisto_alue"
            shoreline.lineColor = NSExpression(forConstantValue: shorelineColor)
            shoreline.lineWidth = zoomRamp([10: 0.6, 14: 1.6, 17: 3])
            style.insertLayer(shoreline, above: waterFill)
        }
    }

    private static func zoomRamp(_ stops: [Double: Double]) -> NSExpression {
        NSExpression(
            format: "mgl_interpolate:withCurveType:parameters:stops:($zoomLevel, 'linear', nil, %@)",
            stops as NSDictionary)
    }

    /// Diagonal stripes rising to the right, as on the raster map: one repeat per 12 pt across,
    /// a third of it green. The raster's stripes scale with zoom (about 8–18 pt); this is fixed
    /// in between. The tile wraps seamlessly because each stripe is drawn three times.
    private static let clearcutHatch: UIImage = {
        let size: CGFloat = 12
        return UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { context in
            let cg = context.cgContext
            cg.setStrokeColor(clearcutHatchColor.cgColor)
            cg.setLineWidth(size / 3 / 2.squareRoot())
            for offset in [-size, 0, size] {
                cg.move(to: CGPoint(x: offset - 1, y: size + 1))
                cg.addLine(to: CGPoint(x: offset + size + 1, y: -1))
            }
            cg.strokePath()
        }
    }()

    /// In a ["match", input, label(s), output, ..., fallback] expression, replaces the output for
    /// `value`, whether it is listed alone or in a label array.
    private static func replacingMatchOutput(_ expression: Any, for value: Int, with output: Any) -> Any {
        guard var array = expression as? [Any], array.first as? String == "match", array.count >= 5 else { return expression }
        for i in stride(from: 2, to: array.count - 1, by: 2) {
            let labels = (array[i] as? [Any]) ?? [array[i]]
            if labels.contains(where: { ($0 as? NSNumber)?.intValue == value }) {
                array[i + 1] = output
            }
        }
        return array
    }

    private static func hex(_ color: UIColor) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }

    /// placeNameScale at a zoom level, interpolated linearly between its stops.
    private static func nameFactor(at zoom: Double) -> Double {
        guard let first = placeNameScale.first, zoom > first.zoom else { return placeNameScale.first?.factor ?? 1 }
        for (a, b) in zip(placeNameScale, placeNameScale.dropFirst()) where zoom <= b.zoom {
            return a.factor + (b.factor - a.factor) * (zoom - a.zoom) / (b.zoom - a.zoom)
        }
        return placeNameScale.last!.factor
    }

    /// Scales a text-size expression by nameFactor. For MML's ["interpolate", curve, ["zoom"],
    /// stop, output, ...] each output is scaled by the factor at its stop, and stops are added
    /// past the last one (where MML's size stays flat) so names keep growing up to zoom 18.
    private static func scaledByZoom(_ expression: Any) -> Any {
        guard let array = expression as? [Any], array.count >= 5, array.first as? String == "interpolate",
              (array[2] as? [Any])?.first as? String == "zoom" else {
            return scaled(expression, by: placeNameScale.first?.factor ?? 1)
        }
        var stops = stride(from: 3, to: array.count - 1, by: 2).compactMap { i -> (Double, Any)? in
            guard let zoom = (array[i] as? NSNumber)?.doubleValue else { return nil }
            return (zoom, array[i + 1])
        }
        guard let last = stops.last else { return expression }
        for zoom in placeNameScale.map(\.zoom) where zoom > last.0 {
            stops.append((zoom, last.1))
        }
        return Array(array[..<3]) + stops.flatMap { zoom, output in [zoom, scaled(output, by: nameFactor(at: zoom))] }
    }

    /// Multiplies the output sizes of a text-size expression, leaving its zoom and priority
    /// stops alone. Zoom curves must stay at the top of an expression, so the factor goes into
    /// each output instead of wrapping the whole thing.
    private static func scaled(_ expression: Any, by k: Double) -> Any {
        if let number = expression as? NSNumber { return number.doubleValue * k }
        guard let array = expression as? [Any], let op = array.first as? String else { return ["*", expression, k] }
        switch op {
        case "interpolate": // [op, curve, input, stop, output, stop, output, ...]
            return Array(array[..<3]) + array[3...].enumerated().map { i, e in i % 2 == 1 ? scaled(e, by: k) : e }
        case "step": // [op, input, output, stop, output, ...]
            return Array(array[..<2]) + array[2...].enumerated().map { i, e in i % 2 == 0 ? scaled(e, by: k) : e }
        default:
            return ["*", expression, k]
        }
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
