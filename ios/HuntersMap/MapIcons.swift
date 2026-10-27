import UIKit

/// Icons for the base map choices, drawn in code as template images (they take the menu's
/// text colour): a topo map with contour lines, the same with pixel-stepped contours for the
/// raster map, and an aerial photo of fields and forest.
enum MapIcons {
    static func icon(for layer: BaseLayer) -> UIImage {
        switch layer {
        case .topo: topo
        case .topoRaster: topoRaster
        case .ortho: ortho
        }
    }

    static let topo = draw { r in
        frame(r).stroke()
        // A hill: nested, slightly irregular contour loops, off-centre like real terrain.
        let loops: [(CGFloat, CGFloat, CGFloat)] = [(0.36, 0.30, 0.10), (0.24, 0.20, 0.07), (0.12, 0.10, 0.04)]
        for (rx, ry, wobble) in loops {
            contour(center: CGPoint(x: r.midX + 1, y: r.midY + 1), rx: rx * r.width, ry: ry * r.height,
                    wobble: wobble * r.width).stroke()
        }
    }

    static let topoRaster = draw { r in
        frame(r).stroke()
        // The same hill, with contours snapped to a pixel grid.
        let loops: [(CGFloat, CGFloat)] = [(0.38, 0.32), (0.24, 0.20), (0.10, 0.08)]
        for (rx, ry) in loops {
            stepped(center: CGPoint(x: r.midX + 1, y: r.midY + 1), rx: rx * r.width, ry: ry * r.height,
                    grid: 1.5).stroke()
        }
    }

    static let ortho = draw { r in
        let outline = frame(r)
        outline.stroke()
        outline.addClip()
        // Field and forest patches seen from above, split by a road.
        let patches = [
            CGRect(x: 0.10, y: 0.10, width: 0.36, height: 0.30),
            CGRect(x: 0.56, y: 0.12, width: 0.34, height: 0.42),
            CGRect(x: 0.10, y: 0.52, width: 0.30, height: 0.38),
        ]
        for p in patches {
            UIBezierPath(roundedRect: CGRect(x: r.minX + p.minX * r.width, y: r.minY + p.minY * r.height,
                                             width: p.width * r.width, height: p.height * r.height),
                         cornerRadius: 1.5).fill()
        }
        // Tree crowns in the remaining corner.
        for (x, y) in [(0.62, 0.70), (0.78, 0.66), (0.70, 0.84), (0.86, 0.82)] {
            UIBezierPath(ovalIn: CGRect(x: r.minX + x * r.width - 2, y: r.minY + y * r.height - 2,
                                        width: 4, height: 4)).fill()
        }
        let road = UIBezierPath()
        road.move(to: CGPoint(x: r.minX, y: r.minY + 0.55 * r.height))
        road.addCurve(to: CGPoint(x: r.maxX, y: r.minY + 0.40 * r.height),
                      controlPoint1: CGPoint(x: r.minX + 0.4 * r.width, y: r.minY + 0.62 * r.height),
                      controlPoint2: CGPoint(x: r.minX + 0.6 * r.width, y: r.minY + 0.36 * r.height))
        // Cut out of the patches, so it reads as a road through the fields.
        road.lineWidth = 2.2
        road.stroke(with: .clear, alpha: 1)
    }

    // MARK: Drawing helpers

    private static let size = CGSize(width: 24, height: 24)

    private static func draw(_ body: (CGRect) -> Void) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { _ in
            UIColor.black.setStroke()
            UIColor.black.setFill()
            body(CGRect(origin: .zero, size: size).insetBy(dx: 2, dy: 2))
        }.withRenderingMode(.alwaysTemplate)
    }

    private static func frame(_ r: CGRect) -> UIBezierPath {
        let path = UIBezierPath(roundedRect: r, cornerRadius: 3)
        path.lineWidth = 1.5
        return path
    }

    /// An ellipse with a gentle wave in its radius, so it reads as a contour, not a circle.
    private static func contour(center c: CGPoint, rx: CGFloat, ry: CGFloat, wobble: CGFloat) -> UIBezierPath {
        let path = UIBezierPath()
        let steps = 48
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
            let k = 1 + (wobble / max(rx, 1)) * sin(3 * t + 0.6)
            let p = CGPoint(x: c.x + rx * k * cos(t), y: c.y + ry * k * sin(t))
            i == 0 ? path.move(to: p) : path.addLine(to: p)
        }
        path.close()
        path.lineWidth = 1.2
        return path
    }

    /// An ellipse traced along a square grid, so it reads as pixels.
    private static func stepped(center c: CGPoint, rx: CGFloat, ry: CGFloat, grid: CGFloat) -> UIBezierPath {
        let snap = { (v: CGFloat, o: CGFloat) in o + ((v - o) / grid).rounded() * grid }
        let path = UIBezierPath()
        var last: CGPoint?
        for i in 0...64 {
            let t = CGFloat(i) / 64 * 2 * .pi
            let p = CGPoint(x: snap(c.x + rx * cos(t), c.x), y: snap(c.y + ry * sin(t), c.y))
            guard let prev = last else { path.move(to: p); last = p; continue }
            guard p != prev else { continue }
            path.addLine(to: CGPoint(x: p.x, y: prev.y)) // horizontal, then vertical: a stair step
            path.addLine(to: p)
            last = p
        }
        path.close()
        path.lineWidth = 1
        path.lineJoinStyle = .miter
        return path
    }
}
