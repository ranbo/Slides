import CoreImage
import CoreImage.CIFilterBuiltins

/// Draws one frame of the show. The preview and the exporter both use this, so what
/// you see while editing is exactly what gets exported.
enum FrameRenderer {
    /// The frame at `time`, covering (0, 0) to `size`. `image` supplies each slide's photo,
    /// or nil if it isn't available yet (that slide draws as black).
    static func render(show: SlideShow, timeline: ShowTimeline, at time: Double, size: CGSize,
                       image: (Slide) -> CIImage?) -> CIImage {
        let frame = CGRect(origin: .zero, size: size)
        let black = CIImage(color: .black).cropped(to: frame)
        var result = black
        for layer in timeline.layers(at: time) {
            let slide = show.slides[layer.index]
            let rects = slide.motionRects(index: layer.index, settings: show.settings)
            let crop = interpolate(rects.from, rects.to, layer.progress)
            let placed = image(slide).map { place($0, crop: crop, in: frame, over: black) } ?? black
            if layer.alpha >= 1 {
                result = placed
            } else if layer.alpha > 0 {
                let dissolve = CIFilter.dissolveTransition()
                dissolve.inputImage = result
                dissolve.targetImage = placed
                dissolve.time = Float(layer.alpha)
                result = dissolve.outputImage?.cropped(to: frame) ?? placed
            }
        }
        return result
    }

    /// Scales and positions the photo so `crop` fills the frame.
    private static func place(_ image: CIImage, crop: NormRect, in frame: CGRect, over black: CIImage) -> CIImage {
        let extent = image.extent
        let cropWidth = crop.width * extent.width
        let cropHeight = crop.height * extent.height
        guard cropWidth > 0, cropHeight > 0 else { return black }
        let left = extent.minX + crop.x * extent.width
        // Core Image's origin is bottom-left; NormRect's is top-left.
        let bottom = extent.minY + (1 - crop.y - crop.height) * extent.height
        let scale = frame.width / cropWidth
        let transform = CGAffineTransform(translationX: -left, y: -bottom)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: 0, y: (frame.height - cropHeight * scale) / 2))
        return image.transformed(by: transform, highQualityDownsample: true)
            .composited(over: black)
            .cropped(to: frame)
    }
}
