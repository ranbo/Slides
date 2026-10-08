import CoreGraphics
import Foundation

/// Finds the white (or yellowed) border around a scanned print.
enum BorderFinder {
    /// A row or column is border if at least this fraction of it is border-colored.
    private static let borderFraction = 0.85
    /// Borders are thin; anything thicker than this fraction of the photo is more likely a
    /// pale wall or sky, and isn't treated as border at all.
    private static let maxTrim = 0.12
    /// A thin dark scanner edge outside the border may be skipped, up to this fraction.
    private static let maxScannerEdge = 0.03
    /// How quickly (as a fraction of the photo) the border must give way to the picture.
    private static let edgeWidth = 0.015
    /// Extra trimmed inside the border, to lose the soft edge between border and picture.
    private static let inset = 0.006

    /// The picture inside the border, in normalized photo coordinates, or nil if there's no border.
    static func contentRect(for url: URL) -> NormRect? {
        guard let image = ImageLoader.cgImage(at: url, maxPixelSize: 600) else { return nil }
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        // Light and nearly colorless; allows for cream and yellowed borders.
        func isBorder(_ x: Int, _ y: Int) -> Bool {
            let i = (y * width + x) * 4
            let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
            let low = min(r, g, b), high = max(r, g, b)
            return low > 165 && high - low < 70
        }
        // Memory row 0 is the top of the photo.
        func rowFraction(_ y: Int) -> Double {
            Double((0..<width).count { isBorder($0, y) }) / Double(width)
        }
        func columnFraction(_ x: Int) -> Double {
            Double((0..<height).count { isBorder(x, $0) }) / Double(height)
        }
        /// Border thickness, in pixels, scanning inward from one edge.
        func thickness(_ count: Int, fromEnd: Bool, _ fraction: (Int) -> Double) -> Int {
            func at(_ i: Int) -> Double { fraction(fromEnd ? count - 1 - i : i) }
            var start = 0
            while start < Int(Double(count) * maxScannerEdge), at(start) < borderFraction { start += 1 }
            guard at(start) >= borderFraction else { return 0 }
            var end = start
            while end < Int(Double(count) * maxTrim), at(end) >= borderFraction { end += 1 }
            // A printed border ends at a sharp edge: just inside it, most of each row is picture.
            // A pale wall or sky fades out gradually instead, so it isn't treated as border.
            let edge = end..<min(end + max(3, Int(Double(count) * edgeWidth)), count)
            guard edge.contains(where: { at($0) < 0.5 }) else { return 0 }
            return end
        }

        let top = thickness(height, fromEnd: false, rowFraction)
        let bottom = thickness(height, fromEnd: true, rowFraction)
        let left = thickness(width, fromEnd: false, columnFraction)
        let right = thickness(width, fromEnd: true, columnFraction)
        guard top + bottom + left + right > 0 else { return nil }

        func side(_ pixels: Int, of count: Int) -> Double {
            pixels == 0 ? 0 : Double(pixels) / Double(count) + inset
        }
        let x0 = side(left, of: width), x1 = 1 - side(right, of: width)
        let y0 = side(top, of: height), y1 = 1 - side(bottom, of: height)
        guard x1 > x0, y1 > y0 else { return nil }
        return NormRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// The crop that loses the border along one axis: the smallest output-shaped rectangle
    /// around the picture, kept within the black-bar rules.
    static func trimmedCrop(content: NormRect, imageAspect: Double, outputAspect: Double) -> NormRect {
        let ratio = FrameMath.normalizedRatio(imageAspect: imageAspect, outputAspect: outputAspect)
        let crop = content.width / content.height > ratio
            ? NormRect(center: content.center, width: content.width, height: content.width / ratio)
            : NormRect(center: content.center, width: content.height * ratio, height: content.height)
        return FrameMath.constrained(crop, imageAspect: imageAspect, outputAspect: outputAspect)
    }
}
