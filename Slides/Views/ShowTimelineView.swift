import SwiftUI

/// The timeline at the bottom of the window: a ruler, the slides staggered on two rows
/// so their cross-fades are visible, and the music clips.
struct ShowTimelineView: View {
    @Binding var document: SlideShowDocument
    @Binding var selection: Set<UUID>
    @Binding var currentID: UUID?
    /// Where a Shift-click range starts; shared with the photo grid.
    @Binding var anchorID: UUID?
    /// Selected music clips. Selecting any clears the photo selection, and vice versa.
    @Binding var selectedClips: Set<UUID>
    let playback: PlaybackController
    /// Timeline zoom level.
    @Binding var pointsPerSecond: Double
    /// The zoom at which the whole show fits the visible width; the timeline keeps it current.
    @Binding var fitPointsPerSecond: Double
    var onSeek: () -> Void
    /// Double-click a photo: edit it.
    var onOpen: (UUID) -> Void
    /// Double-click a music clip: edit it.
    var onOpenClip: (UUID) -> Void
    var onAddAudio: (_ urls: [URL], _ time: Double) -> Void

    static let maxPointsPerSecond = 400.0
    /// Space after the end of the show.
    private static let trailingSpace = 60.0
    static let zoomStep = 1.5
    /// A slide duration being dragged, applied live and committed when the drag ends.
    @State private var durationEdit: (id: UUID, seconds: Double)?
    /// Photos being dragged to a new place: how far, and where the pointer is.
    @State private var slideDrag: (ids: Set<UUID>, translation: CGFloat, location: CGFloat)?
    /// A music clip being moved or trimmed.
    @State private var clipEdit: AudioClip?
    @State private var audioTargeted = false
    @FocusState private var focused: Bool
    @State private var scrollPosition = ScrollPosition(edge: .leading)
    @State private var visibleRect: CGRect = .zero

    private let rulerHeight: CGFloat = 22
    private let slideRowHeight: CGFloat = 46
    private let clipRowHeight: CGFloat = 38
    private let laneSpacing: CGFloat = 6

    private var settings: ShowSettings { document.show.settings }

    private var clips: [AudioClip] {
        document.show.audio.map { $0.id == clipEdit?.id ? clipEdit! : $0 }
    }

    var body: some View {
        let timeline = ShowTimeline(show: document.show, override: durationEdit)
        let clips = self.clips
        let rows = Self.rows(for: clips)
        let audioHeight = CGFloat(max(rows.values.max().map { $0 + 1 } ?? 1, 1)) * clipRowHeight
        let end = max(timeline.duration, clips.map(\.end).max() ?? 0)
        let contentWidth = max(end * pointsPerSecond + Self.trailingSpace, visibleRect.width)
        let slideLaneHeight = slideRowHeight * 2 + 4

        VStack(spacing: 0) {
            header(duration: timeline.duration)
            Divider()
            // Vertical too, so a short timeline scrolls rather than spilling over the divider.
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: laneSpacing) {
                        ruler(width: contentWidth)
                        slideLane(timeline, width: contentWidth)
                            .frame(width: contentWidth, height: slideLaneHeight, alignment: .topLeading)
                        audioLane(clips, rows: rows, width: contentWidth)
                            .frame(width: contentWidth, height: audioHeight, alignment: .topLeading)
                    }
                    PlayheadView(playback: playback, pointsPerSecond: pointsPerSecond)
                        .frame(height: rulerHeight + slideLaneHeight + audioHeight + laneSpacing * 2)
                }
                .padding(.bottom, 8)
                .coordinateSpace(name: "timeline")
            }
            .scrollPosition($scrollPosition)
            .onScrollGeometryChange(for: CGRect.self, of: { $0.visibleRect }) { _, rect in visibleRect = rect }
            .onChange(of: FitInputs(width: visibleRect.width, end: end), initial: true) { _, inputs in
                guard inputs.width > 0 else { return }
                fitPointsPerSecond = (inputs.width - Self.trailingSpace) / max(inputs.end, 1)
            }
            .onChange(of: currentID) { _, id in
                // Keep the photo being edited in view, e.g. when stepping with the arrow keys.
                guard !playback.isPlaying, let id, let entry = timeline.entry(for: id) else { return }
                reveal(entry)
            }
            .onChange(of: pointsPerSecond) { old, new in
                // Keep the playhead at the same place on screen while zooming.
                let onScreen = playback.time * old - visibleRect.minX
                scrollPosition.scrollTo(x: max(0, playback.time * new - onScreen))
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onDeleteCommand(perform: deleteSelection)
        .onCommand(#selector(NSResponder.selectAll(_:)), perform: selectAll)
        .onChange(of: selection) { _, photos in
            if !photos.isEmpty { selectedClips = [] }
        }
    }

    /// Scrolls just enough to show the whole photo (or its start, if it's wider than the view).
    private func reveal(_ entry: ShowTimeline.Entry) {
        guard visibleRect.width > 0 else { return }
        let margin = 24.0
        let minX = entry.start * pointsPerSecond - margin
        let maxX = (entry.start + entry.duration) * pointsPerSecond + margin
        if minX < visibleRect.minX {
            scrollPosition.scrollTo(x: max(0, minX))
        } else if maxX > visibleRect.maxX {
            scrollPosition.scrollTo(x: max(0, min(maxX - visibleRect.width, minX)))
        }
    }

    /// Selects every music clip if a clip is selected, otherwise every photo.
    private func selectAll() {
        if !selectedClips.isEmpty {
            selectedClips = Set(document.show.audio.map(\.id))
        } else {
            selection = Set(document.show.slides.map(\.id))
            if currentID == nil { currentID = document.show.slides.first?.id }
        }
    }

    /// Deletes the selected music clips, or if there are none, the selected photos.
    private func deleteSelection() {
        if !selectedClips.isEmpty {
            document.show.audio.removeAll { selectedClips.contains($0.id) }
            selectedClips = []
        } else if !selection.isEmpty {
            document.removeSlides(selection)
            selection = []
            currentID = nil
        }
    }

    // MARK: - Header and ruler

    private func header(duration: Double) -> some View {
        HStack(spacing: 10) {
            Text("Timeline").font(.headline)
            Text("\(document.show.slides.count) photos · \(formatTime(duration))")
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer()
            PlayheadFollower(playback: playback, pointsPerSecond: pointsPerSecond, visibleRect: visibleRect) { x in
                scrollPosition.scrollTo(x: x)
            }
            Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
            Slider(value: $pointsPerSecond,
                   in: fitPointsPerSecond...max(Self.maxPointsPerSecond, fitPointsPerSecond + 1))
                .frame(width: 140)
                .help("Zoom the timeline (= and -)")
            Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func ruler(width: CGFloat) -> some View {
        Canvas { context, size in
            let pps = pointsPerSecond
            let labelEvery = [1.0, 2, 5, 10, 15, 30, 60, 120, 300, 600].first { $0 * pps >= 60 } ?? 600
            let tickEvery = labelEvery / 5
            for i in 0...Int(size.width / (tickEvery * pps)) {
                let t = Double(i) * tickEvery
                let x = t * pps
                let isLabel = i.isMultiple(of: 5)
                let tickHeight: CGFloat = isLabel ? 10 : 5
                context.fill(Path(CGRect(x: x, y: size.height - tickHeight, width: 1, height: tickHeight)),
                             with: .color(.secondary))
                if isLabel {
                    let whole = Int(t.rounded())
                    let minutes = whole / 60, seconds = whole % 60
                    context.draw(Text(String(format: "%d:%02d", minutes, seconds)).font(.caption2).foregroundStyle(.secondary),
                                 at: CGPoint(x: x + 3, y: 2), anchor: .topLeading)
                }
            }
        }
        .frame(width: width, height: rulerHeight)
        .background(Color(nsColor: .windowBackgroundColor))
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
            onSeek()
            playback.seek(to: value.location.x / pointsPerSecond)
        })
        .help("Click or drag to move the playhead")
    }

    // MARK: - Slides

    private func slideLane(_ timeline: ShowTimeline, width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(timeline.entries, id: \.id) { entry in
                let slide = document.show.slides[entry.index]
                let dragging = slideDrag?.ids.contains(slide.id) == true
                SlideBlock(slide: slide, entry: entry, settings: settings, pointsPerSecond: pointsPerSecond,
                           isSelected: selection.contains(slide.id))
                    .frame(width: max(entry.duration * pointsPerSecond, 4), height: slideRowHeight)
                    .overlay(alignment: .trailing) { durationHandle(for: slide) }
                    .opacity(dragging ? 0.6 : 1)
                    .offset(x: entry.start * pointsPerSecond + (dragging ? slideDrag!.translation : 0),
                            y: entry.index.isMultiple(of: 2) ? 0 : slideRowHeight + 4)
                    .zIndex(dragging ? 1 : 0)
                    .onTapGesture { select(slide.id, entry: entry) }
                    .simultaneousGesture(TapGesture(count: 2).onEnded { onOpen(slide.id) })
                    .gesture(reorderGesture(slide.id, timeline))
                    .contextMenu {
                        Button("Reset Duration") { document.show.slides[entry.index].duration = nil }
                            .disabled(slide.duration == nil)
                        Button("Delete") { document.removeSlides([slide.id]) }
                    }
            }
            if let slideDrag {
                // Where the photos will land.
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 4, height: slideRowHeight * 2 + 4)
                    .offset(x: dropX(slideDrag.location, timeline) - 2)
                    .allowsHitTesting(false)
            }
        }
    }

    /// Dragging a photo moves it, or all the selected photos if it's one of them, to
    /// wherever it's dropped.
    private func reorderGesture(_ id: UUID, _ timeline: ShowTimeline) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("timeline"))
            .onChanged { value in
                let ids = slideDrag?.ids ?? (selection.contains(id) ? selection : [id])
                slideDrag = (ids, value.translation.width, value.location.x)
            }
            .onEnded { value in
                guard let drag = slideDrag else { return }
                slideDrag = nil
                let entries = timeline.entries
                let index = dropIndex(value.location.x, timeline)
                // Land before the first photo at or after the drop point that isn't moving.
                let target = entries[index...].first { !drag.ids.contains($0.id) }
                document.moveSlides(drag.ids, to: target?.id, after: target == nil)
                if !drag.ids.contains(where: selection.contains) { selection = drag.ids }
            }
    }

    /// The index of the photo a drop at `x` goes before (or the count, for the end).
    private func dropIndex(_ x: CGFloat, _ timeline: ShowTimeline) -> Int {
        timeline.entries.firstIndex { x < (($0.start + $0.end) / 2) * pointsPerSecond } ?? timeline.entries.count
    }

    private func dropX(_ x: CGFloat, _ timeline: ShowTimeline) -> CGFloat {
        let index = dropIndex(x, timeline)
        let time = index < timeline.entries.count ? timeline.entries[index].start : timeline.duration
        return time * pointsPerSecond
    }

    private func durationHandle(for slide: Slide) -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.001))
            .frame(width: 8)
            .pointerStyle(.frameResize(position: .trailing))
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("timeline"))
                .onChanged { value in
                    let seconds = slide.duration(settings) + value.translation.width / pointsPerSecond
                    durationEdit = (slide.id, max(ShowTimeline.minimumDuration, (seconds * 10).rounded() / 10))
                }
                .onEnded { _ in
                    if let edit = durationEdit, let i = document.show.slides.firstIndex(where: { $0.id == edit.id }) {
                        document.show.slides[i].duration = edit.seconds
                    }
                    durationEdit = nil
                })
            .help("Drag to change how long this photo is shown")
    }

    private func select(_ id: UUID, entry: ShowTimeline.Entry) {
        focused = true
        selectedClips = []
        guard clickSelect(id, in: document.show.slides, selection: &selection, anchor: &anchorID) else { return }
        // Moving the playhead to the photo happens when it becomes the current photo.
        currentID = id
    }

    // MARK: - Music

    private func audioLane(_ clips: [AudioClip], rows: [UUID: Int], width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(audioTargeted ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.08))
            if clips.isEmpty {
                Text("Drag music files here")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 8)
                    .frame(height: clipRowHeight)
            }
            ForEach(clips) { clip in
                let x = clip.start * pointsPerSecond, width = max(clip.length * pointsPerSecond, 4)
                // Only the part on screen gets a waveform, so zooming far in stays cheap.
                let shown = visibleRect.width > 0
                    ? max(visibleRect.minX - x, 0)...max(min(visibleRect.maxX - x, width), max(visibleRect.minX - x, 0))
                    : 0...min(width, 2000)
                AudioBlock(clip: clip, isSelected: selectedClips.contains(clip.id),
                           pointsPerSecond: pointsPerSecond, shown: shown)
                    .frame(width: width, height: clipRowHeight - 4)
                    .onTapGesture { selectClip(clip.id) }
                    .simultaneousGesture(TapGesture(count: 2).onEnded { onOpenClip(clip.id) })
                    .gesture(clipGesture(clip) { c, dt in c.start = max(0, c.start + dt) })
                    .overlay(alignment: .leading) {
                        trimHandle(clip, edge: .leading) { c, dt in
                            let d = min(max(dt, -c.offset, -c.start), c.length - 0.5)
                            c.start += d
                            c.offset += d
                            c.length -= d
                        }
                    }
                    .overlay(alignment: .trailing) {
                        trimHandle(clip, edge: .trailing) { c, dt in
                            c.length = min(max(0.5, c.length + dt), c.fileDuration - c.offset)
                        }
                    }
                    .offset(x: clip.start * pointsPerSecond, y: CGFloat(rows[clip.id] ?? 0) * clipRowHeight + 2)
                    .contextMenu { clipMenu(clip) }
            }
        }
        .dropDestination(for: URL.self) { urls, location in
            onAddAudio(urls, location.x / pointsPerSecond)
            return true
        } isTargeted: { audioTargeted = $0 }
    }

    private func selectClip(_ id: UUID) {
        focused = true
        if NSEvent.modifierFlags.contains(.command) {
            if selectedClips.contains(id) { selectedClips.remove(id) } else { selectedClips.insert(id) }
        } else {
            selectedClips = [id]
        }
        selection = []
    }

    private func trimHandle(_ clip: AudioClip, edge: HorizontalEdge,
                            change: @escaping (inout AudioClip, Double) -> Void) -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.001))
            .frame(width: 6)
            .pointerStyle(.frameResize(position: edge == .leading ? .leading : .trailing))
            .gesture(clipGesture(clip, change: change))
    }

    /// Edits a copy of the clip while dragging and saves it when the drag ends.
    private func clipGesture(_ clip: AudioClip, change: @escaping (inout AudioClip, Double) -> Void) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("timeline"))
            .onChanged { value in
                if !selectedClips.contains(clip.id) { selectClip(clip.id) }
                guard var edited = document.show.audio.first(where: { $0.id == clip.id }) else { return }
                change(&edited, value.translation.width / pointsPerSecond)
                clipEdit = edited
            }
            .onEnded { _ in
                if let edited = clipEdit, let i = document.show.audio.firstIndex(where: { $0.id == edited.id }) {
                    document.show.audio[i] = edited
                }
                clipEdit = nil
            }
    }

    @ViewBuilder
    private func clipMenu(_ clip: AudioClip) -> some View {
        Button("Edit Gain and Fades…") { onOpenClip(clip.id) }
        Button("Copy Into Document") { document.embedMedia(slideIDs: [], clipIDs: [clip.id]) }
            .disabled(clip.source.isEmbedded)
        Divider()
        Button("Remove") { document.show.audio.removeAll { $0.id == clip.id } }
    }

    private func setClip(_ id: UUID, _ change: (inout AudioClip) -> Void) {
        guard let i = document.show.audio.firstIndex(where: { $0.id == id }) else { return }
        change(&document.show.audio[i])
    }

    /// Puts overlapping clips on separate rows.
    private static func rows(for clips: [AudioClip]) -> [UUID: Int] {
        var rowEnds: [Double] = []
        var rows: [UUID: Int] = [:]
        for clip in clips.sorted(by: { $0.start < $1.start }) {
            if let row = rowEnds.firstIndex(where: { $0 <= clip.start + 0.001 }) {
                rows[clip.id] = row
                rowEnds[row] = clip.end
            } else {
                rows[clip.id] = rowEnds.count
                rowEnds.append(clip.end)
            }
        }
        return rows
    }
}

private struct FitInputs: Equatable {
    var width: CGFloat
    var end: Double
}

private struct SlideBlock: View {
    let slide: Slide
    let entry: ShowTimeline.Entry
    let settings: ShowSettings
    let pointsPerSecond: Double
    let isSelected: Bool

    var body: some View {
        let color: Color = entry.index.isMultiple(of: 2) ? .blue : .purple
        let width = entry.duration * pointsPerSecond
        CroppedThumbnail(slide: slide, settings: settings, fill: true)
            .clipShape(RoundedRectangle(cornerRadius: 2))
            .padding(2)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(color)
            .overlay(alignment: .topTrailing) {
                if width >= 30 { badge("\(entry.index + 1)", bold: true) }
            }
            .overlay(alignment: .bottomTrailing) {
                if width >= 44 { badge(String(format: "%.1fs", entry.duration), bold: slide.duration != nil) }
            }
        .overlay(alignment: .leading) {
            LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: entry.fadeIn * pointsPerSecond)
        }
        .overlay(alignment: .trailing) {
            LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .leading, endPoint: .trailing)
                .frame(width: entry.fadeOut * pointsPerSecond)
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay {
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(isSelected ? Color.yellow : color, lineWidth: isSelected ? 2 : 1)
        }
        .contentShape(Rectangle())
        .help(slide.name)
    }

    private func badge(_ text: String, bold: Bool) -> some View {
        Text(text)
            .font(.caption2.monospacedDigit())
            .fontWeight(bold ? .bold : .regular)
            .foregroundStyle(.white)
            .padding(.horizontal, 3)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 3))
            .padding(3)
    }
}

private struct AudioBlock: View {
    let clip: AudioClip
    let isSelected: Bool
    let pointsPerSecond: Double
    /// The part of the clip on screen, in points from its left edge.
    let shown: ClosedRange<Double>
    @State private var waveform: Waveform?

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 4).fill(Color.green.opacity(0.7))
            if let waveform, shown.upperBound > shown.lowerBound {
                waveformView(waveform)
                    .frame(width: shown.upperBound - shown.lowerBound)
                    .offset(x: shown.lowerBound)
            }
            HStack(spacing: 4) {
                Image(systemName: "music.note")
                Text(clip.name).lineLimit(1)
                if abs(clip.gainDB) >= 0.05 {
                    Text(String(format: "%+.1f dB", clip.gainDB)).foregroundStyle(.white.opacity(0.8))
                }
                Spacer(minLength: 0)
            }
            .font(.caption)
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.6), radius: 1)
            .padding(.horizontal, 6)
        }
        .overlay(alignment: .leading) { fadeShade(clip.fadeInDuration, leading: true) }
        .overlay(alignment: .trailing) { fadeShade(clip.fadeOutDuration, leading: false) }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay {
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(isSelected ? Color.yellow : .clear, lineWidth: 2)
        }
        .contentShape(Rectangle())
        .help(clip.name)
        .task(id: clip.source) { waveform = await WaveformCache.waveform(for: clip.source) }
    }

    /// A fade, drawn as a ramp of shade at the end of the clip.
    private func fadeShade(_ seconds: Double, leading: Bool) -> some View {
        FadeRamp(rising: leading)
            .fill(.black.opacity(0.35))
            .frame(width: seconds * pointsPerSecond)
            .allowsHitTesting(false)
    }

    /// The loudest moment in each couple of points, drawn as a bar centered vertically.
    private func waveformView(_ waveform: Waveform) -> some View {
        Canvas { context, size in
            let step = 2.0
            let scale = Float(clip.volume) * Float(size.height - 2)
            let maxHeight = size.height - 2
            var path = Path()
            var x = 0.0
            while x < size.width {
                let t = clip.offset + (shown.lowerBound + x) / pointsPerSecond
                let height = min(max(CGFloat(waveform.peak(from: t, to: t + step / pointsPerSecond) * scale), 1), maxHeight)
                path.addRect(CGRect(x: x, y: (size.height - height) / 2, width: step - 0.5, height: height))
                x += step
            }
            context.fill(path, with: .color(.black.opacity(0.35)))
        }
        .allowsHitTesting(false)
    }
}

/// The quiet part of a fade: the triangle above a line rising from (or falling to) silence.
private struct FadeRamp: Shape {
    let rising: Bool

    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rising ? rect.minX : rect.maxX, y: rect.maxY))
            path.closeSubpath()
        }
    }
}

/// Kept separate so only this small view redraws as the playhead moves.
private struct PlayheadView: View {
    let playback: PlaybackController
    let pointsPerSecond: Double

    var body: some View {
        Rectangle()
            .fill(Color.red)
            .frame(width: 1.5)
            .offset(x: playback.time * pointsPerSecond)
            .allowsHitTesting(false)
    }
}

/// Scrolls the timeline to keep the playhead in view during playback.
private struct PlayheadFollower: View {
    let playback: PlaybackController
    let pointsPerSecond: Double
    let visibleRect: CGRect
    let scroll: (CGFloat) -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: playback.time) { _, time in
                guard playback.isPlaying, visibleRect.width > 0 else { return }
                let x = time * pointsPerSecond
                if x > visibleRect.maxX - 40 || x < visibleRect.minX {
                    scroll(max(0, x - 40))
                }
            }
    }
}
