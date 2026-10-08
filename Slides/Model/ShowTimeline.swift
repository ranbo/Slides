import Foundation

/// When each slide starts and how it fades, worked out from the slide list and settings.
///
/// Nothing here is stored: inserting, removing or reordering photos simply produces a new
/// timeline, so cross-fades and zoom directions never need fixing by hand.
struct ShowTimeline {
    struct Entry {
        var index: Int
        var id: UUID
        var start: Double
        var duration: Double
        var fadeIn: Double
        var fadeOut: Double
        var end: Double { start + duration }
    }

    struct Layer {
        var index: Int
        /// 0 at the start of the slide's time on screen, 1 at its end.
        var progress: Double
        /// How opaque the slide is over whatever is beneath it.
        var alpha: Double
    }

    static let minimumDuration = 0.3

    let entries: [Entry]
    let duration: Double

    /// `override` replaces one slide's duration, for live feedback while dragging.
    init(show: SlideShow, override: (id: UUID, seconds: Double)? = nil) {
        let settings = show.settings
        let slides = show.slides
        let durations = slides.map { slide in
            max(Self.minimumDuration, slide.id == override?.id ? override!.seconds : slide.duration(settings))
        }
        let fade = max(settings.crossfade, 0)
        // Cross-fade between slide i and i + 1, never more than half of either slide.
        let fades = durations.indices.dropLast().map { i in
            min(fade, durations[i] / 2, durations[i + 1] / 2)
        }

        var entries: [Entry] = []
        var t = 0.0
        for (i, slide) in slides.enumerated() {
            let d = durations[i]
            let isFirst = i == 0, isLast = i == slides.count - 1
            let fadeIn = isFirst ? (settings.fadeInFromBlack ? min(fade, d / 2) : 0) : fades[i - 1]
            let fadeOut = isLast ? (settings.fadeOutToBlack ? min(fade, d / 2) : 0) : fades[i]
            entries.append(Entry(index: i, id: slide.id, start: t, duration: d, fadeIn: fadeIn, fadeOut: fadeOut))
            t += d - (isLast ? 0 : fades[i])
        }
        self.entries = entries
        duration = entries.last?.end ?? 0
    }

    /// The slides visible at `time`, bottom first.
    func layers(at time: Double) -> [Layer] {
        var layers: [Layer] = []
        for entry in entries {
            let isLast = entry.index == entries.count - 1
            guard time >= entry.start, time < entry.end || (isLast && time <= entry.end) else { continue }
            let local = time - entry.start
            var alpha = entry.fadeIn > 0 ? min(local / entry.fadeIn, 1) : 1
            if isLast, entry.fadeOut > 0 {
                alpha *= min((entry.end - time) / entry.fadeOut, 1)
            }
            layers.append(Layer(index: entry.index, progress: min(max(local / entry.duration, 0), 1), alpha: alpha))
        }
        return layers
    }

    func entry(for id: UUID) -> Entry? {
        entries.first { $0.id == id }
    }

    /// The topmost slide at `time`.
    func entry(at time: Double) -> Entry? {
        layers(at: time).last.map { entries[$0.index] }
    }
}
