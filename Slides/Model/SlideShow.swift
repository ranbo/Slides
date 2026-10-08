import CoreGraphics
import Foundation

/// Where a photo or music file lives.
enum MediaSource: Codable, Hashable {
    /// A file elsewhere on disk. The bookmark finds it again if it is moved.
    case file(path: String, bookmark: Data?)
    /// A copy stored inside the document package, in its Media folder.
    case embedded(name: String)

    var embeddedName: String? {
        if case .embedded(let name) = self { return name }
        return nil
    }

    var isEmbedded: Bool { embeddedName != nil }
}

enum MotionKind: String, Codable, CaseIterable {
    case zoom
    case pan
}

enum ZoomDirection: String, Codable, CaseIterable {
    /// Alternates by position: even slides zoom in, odd slides zoom out.
    case auto
    case zoomIn
    case zoomOut
}

struct Slide: Codable, Hashable, Identifiable {
    var id = UUID()
    var source: MediaSource
    var name: String
    /// Pixel width / height of the photo, after applying its EXIF orientation.
    var imageAspect: Double

    /// The widest view of the photo (the "outer" rectangle). nil fills the frame, centered.
    var crop: NormRect?
    /// The point the zoom moves toward, in normalized photo coordinates. nil is the crop's center.
    var focus: CGPoint?
    /// How much smaller the inner rectangle is than the outer one (0.05 = 5%). nil uses the show default.
    var zoom: Double?
    var direction: ZoomDirection = .auto
    var motion: MotionKind = .zoom
    var panStart: NormRect?
    var panEnd: NormRect?
    /// Seconds on screen, including cross-fades. nil uses the show default.
    var duration: Double?
}

struct AudioClip: Codable, Hashable, Identifiable {
    var id = UUID()
    var source: MediaSource
    var name: String
    /// Where the clip begins on the show's timeline, in seconds.
    var start: Double
    /// Where playback begins within the file, in seconds.
    var offset: Double = 0
    var length: Double
    var fileDuration: Double
    var volume: Double = 1

    var end: Double { start + length }
}

struct ShowSettings: Codable, Hashable {
    var slideDuration: Double = 4
    var crossfade: Double = 0.5
    var zoom: Double = 0.05
    var fadeInFromBlack = true
    var fadeOutToBlack = true
    var musicFadeOut: Double = 2
    var frameRate = 30
    var copyMediaIntoDocument = false
    var outputWidth = 1920
    var outputHeight = 1080

    var outputAspect: Double { Double(outputWidth) / Double(outputHeight) }
}

struct SlideShow: Codable, Hashable {
    var settings = ShowSettings()
    var slides: [Slide] = []
    var audio: [AudioClip] = []

    /// Gives a fresh ID to any slide or clip whose ID repeats an earlier one.
    /// Duplicates confuse the photo grid and selection.
    mutating func ensureUniqueIDs() {
        var seen = Set<UUID>()
        for i in slides.indices where !seen.insert(slides[i].id).inserted {
            slides[i].id = UUID()
        }
        seen.removeAll()
        for i in audio.indices where !seen.insert(audio[i].id).inserted {
            audio[i].id = UUID()
        }
    }

    var embeddedNames: Set<String> {
        Set(slides.compactMap(\.source.embeddedName) + audio.compactMap(\.source.embeddedName))
    }
}

extension Slide {
    func normalizedRatio(_ settings: ShowSettings) -> Double {
        FrameMath.normalizedRatio(imageAspect: imageAspect, outputAspect: settings.outputAspect)
    }

    func maxCrop(_ settings: ShowSettings) -> NormRect {
        crop ?? FrameMath.fillRect(imageAspect: imageAspect, outputAspect: settings.outputAspect)
    }

    func focusPoint(_ settings: ShowSettings) -> CGPoint {
        let outer = maxCrop(settings)
        return outer.clamping(focus ?? outer.center)
    }

    func zoomAmount(_ settings: ShowSettings) -> Double {
        min(max(zoom ?? settings.zoom, 0), 0.9)
    }

    /// The outer rectangle shrunk toward the focus point, which stays put on screen.
    func innerRect(_ settings: ShowSettings) -> NormRect {
        maxCrop(settings).scaled(by: 1 - zoomAmount(settings), about: focusPoint(settings))
    }

    func zoomsIn(at index: Int) -> Bool {
        switch direction {
        case .auto: index.isMultiple(of: 2)
        case .zoomIn: true
        case .zoomOut: false
        }
    }

    func defaultPanRects(_ settings: ShowSettings) -> (start: NormRect, end: NormRect) {
        let outer = maxCrop(settings)
        let w = outer.width * 0.75, h = outer.height * 0.75
        let y = outer.center.y - h / 2
        return (NormRect(x: outer.minX, y: y, width: w, height: h),
                NormRect(x: outer.maxX - w, y: y, width: w, height: h))
    }

    func panRects(_ settings: ShowSettings) -> (start: NormRect, end: NormRect) {
        let defaults = defaultPanRects(settings)
        return (panStart ?? defaults.start, panEnd ?? defaults.end)
    }

    /// The rectangles shown at the start and end of this slide when it sits at `index`.
    func motionRects(index: Int, settings: ShowSettings) -> (from: NormRect, to: NormRect) {
        switch motion {
        case .zoom:
            let outer = maxCrop(settings), inner = innerRect(settings)
            return zoomsIn(at: index) ? (outer, inner) : (inner, outer)
        case .pan:
            let rects = panRects(settings)
            return (rects.start, rects.end)
        }
    }

    func duration(_ settings: ShowSettings) -> Double {
        duration ?? settings.slideDuration
    }
}
