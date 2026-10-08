import CoreGraphics
import Foundation

/// A rectangle in normalized photo coordinates: (0, 0) is the photo's top-left
/// corner and (1, 1) its bottom-right, whatever the photo's pixel size.
/// Rectangles may extend past the photo; anything outside it renders black.
struct NormRect: Codable, Hashable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    static let unit = NormRect(x: 0, y: 0, width: 1, height: 1)

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    init(center: CGPoint, width: Double, height: Double) {
        self.init(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
    }

    var minX: Double { x }
    var minY: Double { y }
    var maxX: Double { x + width }
    var maxY: Double { y + height }
    var center: CGPoint { CGPoint(x: x + width / 2, y: y + height / 2) }

    func offsetBy(dx: Double, dy: Double) -> NormRect {
        NormRect(x: x + dx, y: y + dy, width: width, height: height)
    }

    /// Scales the rectangle about `point`, which stays fixed.
    func scaled(by scale: Double, about point: CGPoint) -> NormRect {
        NormRect(x: point.x + (x - point.x) * scale,
                 y: point.y + (y - point.y) * scale,
                 width: width * scale,
                 height: height * scale)
    }

    func union(_ other: NormRect) -> NormRect {
        let x0 = min(minX, other.minX), y0 = min(minY, other.minY)
        return NormRect(x: x0, y: y0, width: max(maxX, other.maxX) - x0, height: max(maxY, other.maxY) - y0)
    }

    func clamping(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, minX), maxX), y: min(max(p.y, minY), maxY))
    }

    /// An output-shaped rectangle with one corner at `anchor`, stretched toward `point`.
    /// `ratio` is width / height in normalized coordinates.
    static func resized(anchor: CGPoint, toward point: CGPoint, ratio: Double, minHeight: Double = 0.05) -> NormRect {
        var w = abs(point.x - anchor.x)
        var h = abs(point.y - anchor.y)
        if w / ratio > h { h = w / ratio } else { w = h * ratio }
        if h < minHeight { h = minHeight; w = h * ratio }
        let x = point.x >= anchor.x ? anchor.x : anchor.x - w
        let y = point.y >= anchor.y ? anchor.y : anchor.y - h
        return NormRect(x: x, y: y, width: w, height: h)
    }
}

/// Moves smoothly from rectangle `a` (at p = 0) to `b` (at p = 1).
///
/// Treats the move as a single uniform zoom about a fixed point, so a zoom toward a face
/// keeps the face still on screen and the zoom speed looks constant (the scale changes
/// geometrically rather than linearly). Equal-sized rectangles give a straight pan.
func interpolate(_ a: NormRect, _ b: NormRect, _ p: Double) -> NormRect {
    func axis(_ a0: Double, _ aLen: Double, _ b0: Double, _ bLen: Double) -> (Double, Double) {
        let k = bLen / aLen
        guard aLen > 0, bLen > 0, abs(k - 1) > 1e-6 else {
            return (a0 + (b0 - a0) * p, aLen + (bLen - aLen) * p)
        }
        let s = pow(k, p)
        let fixed = (b0 - k * a0) / (1 - k)
        return (fixed + (a0 - fixed) * s, aLen * s)
    }
    let (x, w) = axis(a.x, a.width, b.x, b.width)
    let (y, h) = axis(a.y, a.height, b.y, b.height)
    return NormRect(x: x, y: y, width: w, height: h)
}

enum FrameMath {
    /// Width / height, in normalized photo coordinates, of a rectangle whose pixel
    /// shape matches the output frame.
    static func normalizedRatio(imageAspect: Double, outputAspect: Double) -> Double {
        outputAspect / imageAspect
    }

    /// The largest output-shaped rectangle inside the photo, centered (crops the edges).
    static func fillRect(imageAspect: Double, outputAspect: Double) -> NormRect {
        let r = normalizedRatio(imageAspect: imageAspect, outputAspect: outputAspect)
        if r <= 1 {
            return NormRect(x: (1 - r) / 2, y: 0, width: r, height: 1)
        }
        let h = 1 / r
        return NormRect(x: 0, y: (1 - h) / 2, width: 1, height: h)
    }

    /// Keeps a crop from ever showing black on a side *and* on the top or bottom: it is no
    /// bigger than `fitRect`, and along each axis it either stays inside the photo or, when
    /// longer than the photo, covers it completely. Oversized rectangles shrink about `anchor`.
    static func constrained(_ rect: NormRect, imageAspect: Double, outputAspect: Double,
                            anchor: CGPoint? = nil) -> NormRect {
        let fit = fitRect(imageAspect: imageAspect, outputAspect: outputAspect)
        var r = rect
        if r.width > fit.width {
            r = r.scaled(by: fit.width / r.width, about: anchor ?? r.center)
        }
        func clamp(_ origin: Double, _ length: Double) -> Double {
            length <= 1 ? min(max(origin, 0), 1 - length) : min(max(origin, 1 - length), 0)
        }
        r.x = clamp(r.x, r.width)
        r.y = clamp(r.y, r.height)
        return r
    }

    /// The smallest output-shaped rectangle showing the whole photo (adds black bars).
    static func fitRect(imageAspect: Double, outputAspect: Double) -> NormRect {
        let r = normalizedRatio(imageAspect: imageAspect, outputAspect: outputAspect)
        if r >= 1 {
            return NormRect(x: (1 - r) / 2, y: 0, width: r, height: 1)
        }
        let h = 1 / r
        return NormRect(x: 0, y: (1 - h) / 2, width: 1, height: h)
    }
}
