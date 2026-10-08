import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let slideShow = UTType(exportedAs: "com.ranbo.slides.show")
    static let slideClipboard = UTType(exportedAs: "com.ranbo.slides.clipboard")
}

/// A `.slides` package: `show.json` plus a `Media` folder holding any copied photos and music.
struct SlideShowDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.slideShow] }

    var show = SlideShow()
    /// Contents of embedded media files, keyed by file name in the Media folder.
    var media: [String: Data] = [:]

    init() {}

    init(configuration: ReadConfiguration) throws {
        let package = configuration.file
        guard let json = package.fileWrappers?["show.json"]?.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        show = try JSONDecoder().decode(SlideShow.self, from: json)
        show.ensureUniqueIDs()
        for (name, wrapper) in package.fileWrappers?["Media"]?.fileWrappers ?? [:] {
            guard let data = wrapper.regularFileContents else { continue }
            media[name] = data
            MediaStore.stage(name: name, data: data)
        }
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var children = ["show.json": FileWrapper(regularFileWithContents: try encoder.encode(show))]

        // Reuse media already saved in the package so autosave doesn't rewrite every photo.
        let saved = configuration.existingFile?.fileWrappers?["Media"]?.fileWrappers ?? [:]
        var mediaChildren: [String: FileWrapper] = [:]
        for name in show.embeddedNames {
            if let existing = saved[name] {
                mediaChildren[name] = existing
            } else if let data = media[name] {
                mediaChildren[name] = FileWrapper(regularFileWithContents: data)
            }
        }
        if !mediaChildren.isEmpty {
            children["Media"] = FileWrapper(directoryWithFileWrappers: mediaChildren)
        }
        return FileWrapper(directoryWithFileWrappers: children)
    }
}

// MARK: - Editing

extension SlideShowDocument {
    /// Slides for the given image files, copied into the document if the show is set to.
    mutating func makeSlides(for urls: [URL]) -> [Slide] {
        urls.compactMap { url in
            guard let aspect = MediaStore.imageAspect(of: url) else { return nil }
            return Slide(source: source(for: url), name: url.lastPathComponent, imageAspect: aspect)
        }
    }

    mutating func makeAudioClip(for url: URL, duration: Double, at start: Double) -> AudioClip {
        AudioClip(source: source(for: url), name: url.lastPathComponent, start: start,
                  length: duration, fileDuration: duration)
    }

    private mutating func source(for url: URL) -> MediaSource {
        if show.settings.copyMediaIntoDocument, let embedded = embed(url) {
            return embedded
        }
        return MediaStore.fileSource(for: url)
    }

    /// Copies a file into the document.
    mutating func embed(_ url: URL) -> MediaSource? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let ext = url.pathExtension.lowercased()
        let name = UUID().uuidString + (ext.isEmpty ? "" : "." + ext)
        media[name] = data
        MediaStore.stage(name: name, data: data)
        return .embedded(name: name)
    }

    /// Copies referenced files into the document. Pass nil to copy everything.
    mutating func embedMedia(slideIDs: Set<UUID>? = nil, clipIDs: Set<UUID>? = nil) {
        for i in show.slides.indices where slideIDs?.contains(show.slides[i].id) ?? true {
            if let embedded = embedded(show.slides[i].source) { show.slides[i].source = embedded }
        }
        for i in show.audio.indices where clipIDs?.contains(show.audio[i].id) ?? true {
            if let embedded = embedded(show.audio[i].source) { show.audio[i].source = embedded }
        }
    }

    private mutating func embedded(_ source: MediaSource) -> MediaSource? {
        guard !source.isEmbedded, let url = MediaStore.url(for: source) else { return nil }
        return embed(url)
    }

    mutating func insertSlides(_ slides: [Slide], at index: Int) {
        show.slides.insert(contentsOf: slides, at: min(max(index, 0), show.slides.count))
    }

    mutating func removeSlides(_ ids: Set<UUID>) {
        show.slides.removeAll { ids.contains($0.id) }
    }

    /// Moves the slides (keeping their relative order) to just before or after `target`.
    mutating func moveSlides(_ ids: Set<UUID>, to target: UUID?, after: Bool) {
        guard target.map({ !ids.contains($0) }) ?? true else { return }
        let moving = show.slides.filter { ids.contains($0.id) }
        show.slides.removeAll { ids.contains($0.id) }
        var index = show.slides.count
        if let target, let targetIndex = show.slides.firstIndex(where: { $0.id == target }) {
            index = after ? targetIndex + 1 : targetIndex
        }
        show.slides.insert(contentsOf: moving, at: index)
    }
}
