import CoreGraphics
import Foundation
import Vision

/// Finds faces in a photo (just where they are, not who they are) to aim the zoom at.
enum FaceFinder {
    /// Faces smaller than this fraction of the largest face's area are treated as background.
    private static let minimumRelativeArea = 0.15

    /// The point to zoom toward: the center of the face, or of the area the main faces cover.
    /// Nil if there are no faces. Normalized photo coordinates, origin top-left.
    static func focusPoint(for url: URL) -> CGPoint? {
        // ImageLoader returns the photo upright, so Vision's coordinates match the slide's.
        guard let image = ImageLoader.cgImage(at: url, maxPixelSize: 1600) else { return nil }
        let request = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(cgImage: image).perform([request])
        let faces = (request.results ?? []).map(\.boundingBox)
        guard let largest = faces.map({ $0.width * $0.height }).max() else { return nil }
        let main = faces.filter { $0.width * $0.height >= largest * minimumRelativeArea }
        let area = main.dropFirst().reduce(main[0]) { $0.union($1) }
        // Vision's origin is bottom-left.
        return CGPoint(x: area.midX, y: 1 - area.midY)
    }
}

/// Runs a per-photo analysis over many photos, a few at a time.
enum PhotoAnalysis {
    static func run<Result: Sendable>(_ photos: [(id: UUID, url: URL)],
                                      _ analysis: @escaping @Sendable (URL) -> Result?,
                                      progress: @MainActor @escaping (Int) -> Void) async -> [UUID: Result] {
        await withTaskGroup(of: (UUID, Result?).self) { group in
            var results: [UUID: Result] = [:]
            var pending = photos[...]
            var done = 0
            func addNext() {
                guard let photo = pending.popFirst() else { return }
                group.addTask(priority: .utility) { (photo.id, analysis(photo.url)) }
            }
            for _ in 0..<4 { addNext() }
            for await (id, result) in group {
                if let result { results[id] = result }
                done += 1
                await progress(done)
                addNext()
            }
            return results
        }
    }
}
