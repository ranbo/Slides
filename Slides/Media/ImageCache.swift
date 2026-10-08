import AppKit
import CoreImage
import ImageIO

enum ImageLoader {
    /// Decodes the image, scaled down to at most `maxPixelSize` on its long side and upright.
    static func cgImage(at url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// Decoded full-size images for rendering, keeping only the most recently used few.
final class ImageCache: @unchecked Sendable {
    static let preview = ImageCache(maxPixelSize: 2560, capacity: 10)
    /// Posted on the main thread when `prefetch` finishes loading an image.
    static let didLoad = Notification.Name("ImageCacheDidLoad")

    let maxPixelSize: Int
    private let capacity: Int
    private let lock = NSLock()
    private var images: [URL: CIImage] = [:]
    private var recent: [URL] = []
    private var inFlight: Set<URL> = []
    private var failed: Set<URL> = []

    init(maxPixelSize: Int, capacity: Int) {
        self.maxPixelSize = maxPixelSize
        self.capacity = capacity
    }

    func cachedImage(for url: URL) -> CIImage? {
        lock.withLock {
            guard let image = images[url] else { return nil }
            touch(url)
            return image
        }
    }

    /// Returns the image, loading it on this thread if needed.
    func image(for url: URL) -> CIImage? {
        if let cached = cachedImage(for: url) { return cached }
        guard let cgImage = ImageLoader.cgImage(at: url, maxPixelSize: maxPixelSize) else { return nil }
        let image = CIImage(cgImage: cgImage)
        lock.withLock { insert(image, for: url) }
        return image
    }

    /// Starts loading the image in the background if it isn't cached.
    func prefetch(_ url: URL) {
        let shouldLoad = lock.withLock {
            guard images[url] == nil, !inFlight.contains(url), !failed.contains(url) else { return false }
            inFlight.insert(url)
            return true
        }
        guard shouldLoad else { return }
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let image = ImageLoader.cgImage(at: url, maxPixelSize: maxPixelSize).map { CIImage(cgImage: $0) }
            lock.withLock {
                inFlight.remove(url)
                if let image { insert(image, for: url) } else { failed.insert(url) }
            }
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Self.didLoad, object: self)
            }
        }
    }

    // Callers hold the lock.
    private func touch(_ url: URL) {
        recent.removeAll { $0 == url }
        recent.append(url)
    }

    private func insert(_ image: CIImage, for url: URL) {
        images[url] = image
        touch(url)
        while recent.count > capacity {
            images.removeValue(forKey: recent.removeFirst())
        }
    }
}

/// Small images for the grid, timeline and crop editor.
final class ThumbnailCache: @unchecked Sendable {
    static let grid = ThumbnailCache(maxPixelSize: 480)
    static let editor = ThumbnailCache(maxPixelSize: 2048, countLimit: 20)

    let maxPixelSize: Int
    private let cache = NSCache<NSURL, NSImage>()

    init(maxPixelSize: Int, countLimit: Int = 500) {
        self.maxPixelSize = maxPixelSize
        cache.countLimit = countLimit
    }

    func image(for source: MediaSource) async -> NSImage? {
        guard let url = MediaStore.url(for: source) else { return nil }
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        let size = maxPixelSize
        guard let cgImage = await Task.detached(priority: .userInitiated, operation: {
            ImageLoader.cgImage(at: url, maxPixelSize: size)
        }).value else { return nil }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        cache.setObject(image, forKey: url as NSURL)
        return image
    }
}
