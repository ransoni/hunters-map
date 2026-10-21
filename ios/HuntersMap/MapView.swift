import SwiftUI
import MapLibre

// Topo base map (TopoStyle.json) with the pienriista-alueet on top: every kanalintu area
// is outlined faintly, the selected one is filled and outlined like on the web map.
struct MapView: UIViewRepresentable {
    let areas: [Area]
    let selected: Area?
    @Binding var trackingMode: MLNUserTrackingMode
    /// Bumped by the caller to fit the map to the selected area again.
    let fitRequest: Int
    /// Zoom by `delta` levels, applied once per new `id` (the zoom buttons).
    let zoomStep: ZoomStep?
    /// Recently walked track, oldest first, drawn as a trail that fades over TrackRecorder.window.
    let track: [TrackPoint]

    struct ZoomStep: Equatable {
        let id: Int
        let delta: Double
    }

    static let finland = MLNCoordinateBounds(
        sw: CLLocationCoordinate2D(latitude: 59.7, longitude: 19.1),
        ne: CLLocationCoordinate2D(latitude: 70.1, longitude: 31.6)
    )
    static let color = UIColor(red: 0xE8 / 255, green: 0x43 / 255, blue: 0x0C / 255, alpha: 1)
    static let labelColor = UIColor(red: 0x8A / 255, green: 0x26 / 255, blue: 0x04 / 255, alpha: 1)
    static let trailColor = UIColor(red: 0x1E / 255, green: 0x4B / 255, blue: 0xD8 / 255, alpha: 1)

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> MLNMapView {
        let styleURL = Bundle.main.url(forResource: "TopoStyle", withExtension: "json")
        let mapView = MLNMapView(frame: .zero, styleURL: styleURL)
        mapView.delegate = context.coordinator
        mapView.maximumZoomLevel = 18
        mapView.showsUserLocation = true
        mapView.showsScale = true
        mapView.scaleBarPosition = .bottomLeft
        mapView.scaleBarMargins = CGPoint(x: 16, y: 44) // above the MapLibre logo
        mapView.compassViewMargins = CGPoint(x: 16, y: 120)
        return mapView
    }

    func updateUIView(_ mapView: MLNMapView, context: Context) {
        context.coordinator.parent = self
        if mapView.userTrackingMode != trackingMode {
            mapView.setUserTrackingMode(trackingMode, animated: true, completionHandler: nil)
        }
        context.coordinator.applySelection(to: mapView)
        context.coordinator.updateTrail(on: mapView)
        if let step = zoomStep, step.id != context.coordinator.zoomedStep {
            context.coordinator.zoomedStep = step.id
            mapView.setZoomLevel(mapView.zoomLevel + step.delta, animated: true)
        }
    }

    final class Coordinator: NSObject, MLNMapViewDelegate {
        var parent: MapView
        var zoomedStep = 0
        private var styleLoaded = false
        private var shownCode: String?? = .none // .none = nothing applied yet
        private var fittedRequest = 0
        private var drawnTrack: [TrackPoint] = []
        private var trailTimer: Timer?

        init(_ parent: MapView) { self.parent = parent }

        deinit { trailTimer?.invalidate() }

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            addAreaLayers(to: style)
            addTrailLayers(to: style)
            styleLoaded = true
            updateTrail(on: mapView, force: true)
            // Segments age even when standing still, so the fade is recomputed every few seconds.
            trailTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self, weak mapView] _ in
                guard let self, let mapView else { return }
                self.updateTrail(on: mapView, force: true)
            }
            // The view has its real size only now; fitting in makeUIView left the map at world zoom.
            if parent.selected == nil {
                let padding = UIEdgeInsets(top: 90, left: 20, bottom: 40, right: 20)
                mapView.setVisibleCoordinateBounds(MapView.finland, edgePadding: padding, animated: false, completionHandler: nil)
            }
            applySelection(to: mapView)
        }

        func mapView(_ mapView: MLNMapView, didChange mode: MLNUserTrackingMode, animated: Bool) {
            if parent.trackingMode != mode {
                DispatchQueue.main.async { self.parent.trackingMode = mode }
            }
        }

        /// Shows the selected area and fits the map to it when it changes or a fit is requested.
        func applySelection(to mapView: MLNMapView) {
            guard styleLoaded, let style = mapView.style else { return }
            let code = parent.selected?.code
            let changed = shownCode != .some(code)
            let refit = parent.fitRequest != fittedRequest
            guard changed || refit else { return }
            shownCode = .some(code)
            fittedRequest = parent.fitRequest

            let predicate = NSPredicate(format: "code == %@", code ?? "")
            for id in ["selected-fill", "selected-casing", "selected-line"] {
                (style.layer(withIdentifier: id) as? MLNVectorStyleLayer)?.predicate = predicate
            }
            if let labels = style.layer(withIdentifier: "area-labels") as? MLNSymbolStyleLayer {
                labels.textColor = NSExpression(
                    format: "TERNARY(code == %@, %@, %@)", code ?? "", MapView.labelColor, UIColor.darkGray
                )
            }

            guard let area = parent.selected else { return }
            // Following the user would immediately pull the map away from the area.
            if mapView.userTrackingMode != .none {
                mapView.userTrackingMode = .none
                let trackingMode = parent.$trackingMode
                DispatchQueue.main.async { trackingMode.wrappedValue = .none }
            }
            let b = area.bbox
            let bounds = MLNCoordinateBounds(
                sw: CLLocationCoordinate2D(latitude: b[1], longitude: b[0]),
                ne: CLLocationCoordinate2D(latitude: b[3], longitude: b[2])
            )
            let padding = UIEdgeInsets(top: 130, left: 40, bottom: 120, right: 40)
            mapView.setVisibleCoordinateBounds(bounds, edgePadding: padding, animated: true, completionHandler: nil)
        }

        private func addAreaLayers(to style: MLNStyle) {
            guard let url = Bundle.main.url(forResource: "areas", withExtension: "geojson") else { return }
            let kanalintuCodes = parent.areas.map(\.code)
            let source = MLNShapeSource(identifier: "areas", url: url, options: nil)
            style.addSource(source)

            let isKanalintu = NSPredicate(format: "code IN %@", kanalintuCodes)
            let nothing = NSPredicate(format: "code == ''")

            let allLine = MLNLineStyleLayer(identifier: "areas-line", source: source)
            allLine.predicate = isKanalintu
            allLine.lineColor = NSExpression(forConstantValue: MapView.color)
            allLine.lineOpacity = NSExpression(forConstantValue: 0.55)
            allLine.lineWidth = Self.zoomRamp([5: 0.6, 12: 1.5])
            allLine.lineDashPattern = NSExpression(forConstantValue: [3, 2])
            style.addLayer(allLine)

            let fill = MLNFillStyleLayer(identifier: "selected-fill", source: source)
            fill.predicate = nothing
            fill.fillColor = NSExpression(forConstantValue: MapView.color)
            fill.fillOpacity = NSExpression(forConstantValue: 0.15)
            style.addLayer(fill)

            let casing = MLNLineStyleLayer(identifier: "selected-casing", source: source)
            casing.predicate = nothing
            casing.lineColor = NSExpression(forConstantValue: UIColor.white)
            casing.lineOpacity = NSExpression(forConstantValue: 0.75)
            casing.lineWidth = Self.zoomRamp([6: 2, 9: 4, 13: 6])
            style.addLayer(casing)

            let line = MLNLineStyleLayer(identifier: "selected-line", source: source)
            line.predicate = nothing
            line.lineColor = NSExpression(forConstantValue: MapView.color)
            line.lineWidth = Self.zoomRamp([5: 1.5, 12: 3])
            style.addLayer(line)

            // Area names at each area's label point (computed inside the area by build_web_data.py).
            let points: [MLNPointFeature] = parent.areas.map { area in
                let point = MLNPointFeature()
                point.coordinate = area.labelCoordinate
                point.attributes = ["code": area.code, "name": area.name]
                return point
            }
            let labelSource = MLNShapeSource(
                identifier: "area-labels", shape: MLNShapeCollectionFeature(shapes: points), options: nil
            )
            style.addSource(labelSource)
            let labels = MLNSymbolStyleLayer(identifier: "area-labels", source: labelSource)
            labels.minimumZoomLevel = 5.5
            labels.text = NSExpression(forKeyPath: "name")
            labels.textFontNames = NSExpression(forConstantValue: ["Open Sans Semibold"])
            labels.textFontSize = Self.zoomRamp([6: 11, 11: 15])
            labels.maximumTextWidth = NSExpression(forConstantValue: 9)
            labels.textColor = NSExpression(forConstantValue: UIColor.darkGray)
            labels.textHaloColor = NSExpression(forConstantValue: UIColor.white.withAlphaComponent(0.95))
            labels.textHaloWidth = NSExpression(forConstantValue: 1.6)
            style.addLayer(labels)
        }

        /// Redraws the trail when the track changed (or always with `force`, to refresh the ages).
        func updateTrail(on mapView: MLNMapView, force: Bool = false) {
            guard styleLoaded,
                  let source = mapView.style?.source(withIdentifier: "trail") as? MLNShapeSource else { return }
            let track = parent.track
            guard force || track != drawnTrack else { return }
            drawnTrack = track

            // One polyline per 20 s age bucket, tagged with its age in minutes for the fading style.
            // (Per-point segments would overlap at every join and stack up their opacity.)
            let bucket: TimeInterval = 20
            let now = Date.now
            var pieces: [MLNPolylineFeature] = []
            var run: [CLLocationCoordinate2D] = []
            var runBucket = -1
            func flush() {
                if run.count >= 2 {
                    let piece = MLNPolylineFeature(coordinates: &run, count: UInt(run.count))
                    piece.attributes = ["age": (Double(runBucket) + 0.5) * bucket / 60]
                    pieces.append(piece)
                }
                run = []
            }
            for (a, b) in zip(track, track.dropFirst()) {
                let age = now.timeIntervalSince(b.time)
                // Skip ends past the window and jumps after a GPS gap (they'd draw a false straight line).
                guard age <= TrackRecorder.window, b.time.timeIntervalSince(a.time) < 120 else {
                    flush()
                    continue
                }
                let ageBucket = Int(age / bucket)
                if ageBucket != runBucket || run.isEmpty {
                    flush()
                    runBucket = ageBucket
                    run = [a.coordinate]
                }
                run.append(b.coordinate)
            }
            flush()
            source.shape = MLNShapeCollectionFeature(shapes: pieces)
        }

        private func addTrailLayers(to style: MLNStyle) {
            let source = MLNShapeSource(identifier: "trail", shape: nil, options: nil)
            style.addSource(source)
            let minutes = TrackRecorder.window / 60
            // Newest segments opaque, fading out towards the end of the window.
            let fade = NSExpression(
                format: "mgl_interpolate:withCurveType:parameters:stops:(age, 'linear', nil, %@)",
                [0: 1, minutes * 0.5: 0.6, minutes: 0.05] as NSDictionary
            )
            let below = style.layer(withIdentifier: "area-labels")

            let casing = MLNLineStyleLayer(identifier: "trail-casing", source: source)
            casing.lineColor = NSExpression(forConstantValue: UIColor.white)
            casing.lineOpacity = fade
            casing.lineWidth = Self.zoomRamp([10: 4, 16: 8])
            casing.lineCap = NSExpression(forConstantValue: "butt")
            casing.lineJoin = NSExpression(forConstantValue: "round")

            let line = MLNLineStyleLayer(identifier: "trail-line", source: source)
            line.lineColor = NSExpression(forConstantValue: MapView.trailColor)
            line.lineOpacity = fade
            line.lineWidth = Self.zoomRamp([10: 2, 16: 4.5])
            line.lineCap = NSExpression(forConstantValue: "butt")
            line.lineJoin = NSExpression(forConstantValue: "round")

            for layer in [casing, line] {
                if let below { style.insertLayer(layer, below: below) } else { style.addLayer(layer) }
            }
        }

        private static func zoomRamp(_ stops: [Double: Double]) -> NSExpression {
            NSExpression(
                format: "mgl_interpolate:withCurveType:parameters:stops:($zoomLevel, 'linear', nil, %@)",
                stops as NSDictionary
            )
        }
    }
}
