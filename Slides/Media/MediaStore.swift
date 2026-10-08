import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers
import os

/// Finds media files on disk and reads basic facts about them.
enum MediaStore {
    /// Embedded media is written here so everything can be read from a URL.
    static let embeddedDirectory: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SlidesEmbeddedMedia", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private static let resolved = OSAllocatedUnfairLock<[MediaSource: URL]>(initialState: [:])

    /// The file's current location, or nil if it can't be found.
    static func url(for source: MediaSource) -> URL? {
        switch source {
        case .embedded(let name):
            return embeddedDirectory.appendingPathComponent(name)
        case .file(let path, let bookmark):
            if let cached = resolved.withLock({ $0[source] }) { return cached }
            var url: URL?
            if FileManager.default.fileExists(atPath: path) {
                url = URL(fileURLWithPath: path)
            } else if let bookmark {
                var stale = false
                if let found = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI],
                                        relativeTo: nil, bookmarkDataIsStale: &stale),
                   FileManager.default.fileExists(atPath: found.path) {
                    url = found
                }
            }
            if let url { resolved.withLock { $0[source] = url } }
            return url
        }
    }

    static func fileSource(for url: URL) -> MediaSource {
        .file(path: url.path, bookmark: try? url.bookmarkData())
    }

    static func stage(name: String, data: Data) {
        let url = embeddedDirectory.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? data.write(to: url)
        }
    }

    /// Width / height of the image as displayed (EXIF orientation applied).
    static func imageAspect(of url: URL) -> Double? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width > 0, height > 0
        else { return nil }
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return (5...8).contains(orientation) ? height / width : width / height
    }

    static func audioDuration(of url: URL) async -> Double? {
        guard let duration = try? await AVURLAsset(url: url).load(.duration).seconds,
              duration.isFinite, duration > 0 else { return nil }
        return duration
    }

    static func isImage(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
    }

    static func isAudio(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .audio) ?? false
    }

    /// Replaces folders with the matching files inside them, sorted by name.
    static func expand(_ urls: [URL], keeping keep: (URL) -> Bool) -> [URL] {
        urls.flatMap { url -> [URL] in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return [] }
            guard isDirectory.boolValue else { return keep(url) ? [url] : [] }
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            return contents.filter(keep).sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }
        }
    }
}

/// Loads file URLs out of drag-and-drop or pasteboard item providers.
enum ItemProviderLoader {
    static func fileURLs(from providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
        let group = DispatchGroup()
        var urls = [URL?](repeating: nil, count: providers.count)
        for (i, provider) in providers.enumerated() where provider.canLoadObject(ofClass: URL.self) {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                DispatchQueue.main.async {
                    urls[i] = url
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) {
            completion(urls.compactMap { $0 }.filter(\.isFileURL))
        }
    }
}
