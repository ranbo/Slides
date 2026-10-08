import SwiftUI

/// The timeline at the bottom of the window: a ruler, the slides staggered on two rows
/// so their cross-fades are visible, and the music clips.
struct ShowTimelineView: View {
    @Binding var document: SlideShowDocument
    @Binding var selection: Set<UUID>
    @Binding var currentID: UUID?
    let playback: PlaybackController
    /// Timeline zoom level.
    @Binding var pointsPerSecond: Double
    /// The zoom at which the whole show fits the visible width; the timeline keeps it current.
    @Binding var fitPointsPerSecond: Double
    var onSeek: () -> Void
    /// Double-click a photo: edit it.
    var onOpen: (UUID) -> Void
    var onAddAudio: (_ urls: [URL], _ time: Double) -> Void

    static let maxPointsPerSecond = 400.0
    /// Space after the end of the show.
    private static let trailingSpace = 60.0
    static let zoomStep = 1.5
    /// A slide duration being dragged, applied live and committed when the drag ends.
    @State private var durationEdit: (id: UUID, seconds: Double)?
    /// A music clip being moved or trimmed.
    @State private var clipEdit: AudioClip?
    @State private var audioTargeted = false
    @State private var selectedClips: Set<UUID> = []
    @FocusState private var focused: Bool
    @State private var scrollPosition = ScrollPosition(edge: .leading)
    @State private var visibleRect: CGRect = .zero

    private let rulerHeight: CGFloat = 22
    private let slideRowHeight: CGFloat = 46
    private let clipRowHeight: CGFloat = 30
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
            ScrollView(.horizontal) {
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
                SlideBlock(slide: slide, entry: entry, settings: settings, pointsPerSecond: pointsPerSecond,
                           isSelected: selection.contains(slide.id))
                    .frame(width: max(entry.duration * pointsPerSecond, 4), height: slideRowHeight)
                    .overlay(alignment: .trailing) { durationHandle(for: slide) }
                    .offset(x: entry.start * pointsPerSecond,
                            y: entry.index.isMultiple(of: 2) ? 0 : slideRowHeight + 4)
                    .onTapGesture { select(slide.id, entry: entry) }
                    .simultaneousGesture(TapGesture(count: 2).onEnded { onOpen(slide.id) })
                    .contextMenu {
                        Button("Reset Duration") { document.show.slides[entry.index].duration = nil }
                            .disabled(slide.duration == nil)
                        Button("Delete") { document.removeSlides([slide.id]) }
                    }
            }
        }
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
        if NSEvent.modifierFlags.contains(.command) {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        } else {
            selection = [id]
        }
        currentID = id
        if !playback.isPlaying { playback.seek(to: entry.start + entry.fadeIn) }
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
                AudioBlock(clip: clip, isSelected: selectedClips.contains(clip.id))
                    .frame(width: max(clip.length * pointsPerSecond, 4), height: clipRowHeight - 4)
                    .onTapGesture { selectClip(clip.id) }
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
        Menu("Volume") {
            ForEach([1.0, 0.75, 0.5, 0.25], id: \.self) { volume in
                Button {
                    setClip(clip.id) { $0.volume = volume }
                } label: {
                    if abs(clip.volume - volume) < 0.01 { Label("\(Int(volume * 100))%", systemImage: "checkmark") }
                    else { Text("\(Int(volume * 100))%") }
                }
            }
        }
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
        HStack(spacing: 6) {
            CroppedThumbnail(slide: slide, settings: settings)
                .frame(height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 2))
            VStack(alignment: .leading, spacing: 1) {
                Text("\(entry.index + 1)").font(.caption.bold())
                Text(String(format: "%.1fs", entry.duration))
                    .font(.caption2.monospacedDigit())
                    .fontWeight(slide.duration == nil ? .regular : .bold)
            }
            .foregroundStyle(.white)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(color.opacity(0.75))
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
}

private struct AudioBlock: View {
    let clip: AudioClip
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "music.note")
            Text(clip.name).lineLimit(1)
            if clip.volume < 0.99 {
                Text("\(Int(clip.volume * 100))%").foregroundStyle(.white.opacity(0.7))
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.green.opacity(0.7), in: RoundedRectangle(cornerRadius: 4))
        .overlay {
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(isSelected ? Color.yellow : .clear, lineWidth: 2)
        }
        .contentShape(Rectangle())
        .help(clip.name)
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
