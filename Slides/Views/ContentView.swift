import SwiftUI
import UniformTypeIdentifiers

enum EditorMode: Hashable {
    case edit
    case preview
}

struct ContentView: View {
    @Binding var document: SlideShowDocument
    var fileURL: URL?

    @State private var selection: Set<UUID> = []
    @State private var currentID: UUID?
    @State private var mode: EditorMode = .edit
    @State private var playback = PlaybackController()
    @State private var showingSettings = false
    @State private var export: ExportProgress?
    /// Playback was started from Edit mode, so stopping returns there.
    @State private var returnToEdit = false
    @AppStorage("timelineHeight") private var timelineHeight = 210.0
    @AppStorage("timelinePointsPerSecond") private var pointsPerSecond = 40.0
    @State private var fitPointsPerSecond = 1.0

    private var show: SlideShow { document.show }

    var body: some View {
        let timeline = ShowTimeline(show: show)
        GeometryReader { geo in
            // The editor and timeline split is our own so its position is remembered.
            let maxTimeline = max(geo.size.height - 300, 120)
            VStack(spacing: 0) {
                HSplitView {
                    PhotoGridView(document: $document, selection: $selection, currentID: $currentID,
                                  onAddPhotos: addPhotos, onOpen: openInEditor)
                        .frame(minWidth: 240, idealWidth: 380)
                    mainPane
                        .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxHeight: .infinity)
                SplitHandle(height: $timelineHeight, range: 120...maxTimeline)
                ShowTimelineView(document: $document, selection: $selection, currentID: $currentID,
                                 playback: playback, pointsPerSecond: $pointsPerSecond,
                                 fitPointsPerSecond: $fitPointsPerSecond,
                                 onSeek: { mode = .preview }, onOpen: openInEditor, onAddAudio: addAudio)
                    .frame(height: min(max(timelineHeight, 120), maxTimeline))
            }
        }
        .background { hiddenShortcuts }
        .focusedSceneValue(\.showCommands, ShowCommands(playback: playback, zoomTimeline: zoomTimeline))
        .toolbar { toolbar }
        .sheet(item: $export) { progress in
            ExportSheet(progress: progress) { export = nil }
        }
        .onChange(of: fitPointsPerSecond) { old, fit in
            // Stay fully zoomed out if we were, and never zoom out past the whole show.
            if pointsPerSecond <= old * 1.001 || pointsPerSecond < fit { pointsPerSecond = fit }
        }
        .onAppear { playback.duration = timeline.duration }
        .onChange(of: timeline.duration) { _, duration in playback.duration = duration }
        .onChange(of: currentID) { _, id in
            // In preview, picking a photo jumps to it.
            guard mode == .preview, !playback.isPlaying, let id, let entry = timeline.entry(for: id) else { return }
            playback.seek(to: entry.start + entry.fadeIn)
        }
        .task(id: AudioKey(clips: show.audio, fadeOut: show.settings.musicFadeOut, duration: timeline.duration)) {
            let audio = await AudioComposer.build(show: show, totalDuration: timeline.duration)
            guard !Task.isCancelled else { return }
            playback.setAudio(audio)
        }
    }

    @ViewBuilder
    private var mainPane: some View {
        switch mode {
        case .edit:
            if let index = show.slides.firstIndex(where: { $0.id == currentID }) {
                let ids = editTargets
                SlideEditorView(slide: slideBinding(show.slides[index]), index: index, settings: show.settings,
                                editCount: ids.count,
                                allEmbedded: show.slides.filter { ids.contains($0.id) }.allSatisfy(\.source.isEmbedded),
                                apply: { change in applyToSlides(ids, change) },
                                onCopyIntoDocument: { document.embedMedia(slideIDs: ids, clipIDs: []) },
                                onPreview: { previewSlide(at: index) })
                    // A fresh editor per photo, so no half-finished edit carries over.
                    .id(show.slides[index].id)
            } else {
                ContentUnavailableView(show.slides.isEmpty ? "No Photos" : "No Photo Selected",
                                       systemImage: "photo.on.rectangle",
                                       description: Text(show.slides.isEmpty
                                           ? "Add photos with the + button, or drag them into the list."
                                           : "Select a photo to set its crop and zoom."))
            }
        case .preview:
            VStack(spacing: 0) {
                PreviewView(show: show, playback: playback)
                    .aspectRatio(show.settings.outputAspect, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.black)
                TransportBar(playback: playback, togglePlay: togglePlay)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button("Add Photos", systemImage: "photo.badge.plus", action: chooseFiles(images: true))
                .help("Add photos")
            Button("Add Music", systemImage: "music.note", action: chooseFiles(images: false))
                .help("Add music at the end of the existing music")
        }
        ToolbarItem(placement: .principal) {
            Picker("Mode", selection: $mode) {
                Label("Edit", systemImage: "crop").tag(EditorMode.edit)
                Label("Preview", systemImage: "play.rectangle").tag(EditorMode.preview)
            }
            .pickerStyle(.segmented)
            .labelStyle(.titleAndIcon)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button(playback.isPlaying ? "Pause" : "Play",
                   systemImage: playback.isPlaying ? "pause.fill" : "play.fill", action: togglePlay)
            .keyboardShortcut(.space, modifiers: [])
            .help("Play or pause (Space)")
            Button("Settings", systemImage: "slider.horizontal.3") { showingSettings.toggle() }
                .help("Show settings")
                .popover(isPresented: $showingSettings) {
                    ShowSettingsView(settings: $document.show.settings) { document.embedMedia() }
                }
            Button("Export", systemImage: "square.and.arrow.up", action: startExport)
                .help("Export a movie")
                .disabled(show.slides.isEmpty)
        }
    }

    /// A binding that finds the slide by ID when writing, so an edit made to one photo can
    /// never land on another, even if the list changed in the meantime.
    private func slideBinding(_ slide: Slide) -> Binding<Slide> {
        Binding(
            get: { document.show.slides.first { $0.id == slide.id } ?? slide },
            set: { edited in
                if let i = document.show.slides.firstIndex(where: { $0.id == edited.id }) {
                    document.show.slides[i] = edited
                }
            })
    }

    /// The photos the editor's controls change: the selection if it includes the photo
    /// being edited, otherwise just that photo.
    private var editTargets: Set<UUID> {
        guard let currentID else { return [] }
        return selection.contains(currentID) ? selection : [currentID]
    }

    /// Changes several slides as a single undo step.
    private func applyToSlides(_ ids: Set<UUID>, _ change: (inout Slide) -> Void) {
        var updated = document
        for i in updated.show.slides.indices where ids.contains(updated.show.slides[i].id) {
            change(&updated.show.slides[i])
        }
        document = updated
    }

    // MARK: - Actions

    /// Plays in Preview mode. Started from Edit mode, it plays from the photo being edited, and
    /// stopping goes back to Edit mode on the photo that was showing.
    private func togglePlay() {
        let timeline = ShowTimeline(show: show)
        if playback.isPlaying {
            playback.pause()
            if returnToEdit, let entry = timeline.entry(at: playback.time) {
                mode = .edit
                currentID = entry.id
                selection = [entry.id]
            }
            returnToEdit = false
        } else {
            returnToEdit = mode == .edit
            if mode == .edit, let currentID, let entry = timeline.entry(for: currentID) {
                playback.seek(to: entry.start)
            }
            mode = .preview
            playback.play()
        }
    }

    private func openInEditor(_ id: UUID) {
        if playback.isPlaying { playback.pause() }
        returnToEdit = false
        mode = .edit
        currentID = id
        if !selection.contains(id) { selection = [id] }
    }

    private func zoomTimeline(by factor: Double) {
        pointsPerSecond = min(max(pointsPerSecond * factor, fitPointsPerSecond),
                              max(ShowTimelineView.maxPointsPerSecond, fitPointsPerSecond))
    }

    /// Selects the previous or next photo. In a text field, the arrow keys move the cursor instead.
    private func stepPhoto(by step: Int) {
        if let textView = NSApp.keyWindow?.firstResponder as? NSTextView {
            step < 0 ? textView.moveLeft(nil) : textView.moveRight(nil)
            return
        }
        let slides = show.slides
        guard !slides.isEmpty else { return }
        let index = slides.firstIndex { $0.id == currentID }
            .map { min(max($0 + step, 0), slides.count - 1) } ?? (step > 0 ? 0 : slides.count - 1)
        currentID = slides[index].id
        selection = [slides[index].id]
    }

    /// Keyboard shortcuts without menu items: ⌘= and ⌘- zoom the timeline (the menu items
    /// use the plain keys), and the arrow keys step through the photos.
    private var hiddenShortcuts: some View {
        Group {
            Button("") { zoomTimeline(by: ShowTimelineView.zoomStep) }.keyboardShortcut("=", modifiers: .command)
            Button("") { zoomTimeline(by: 1 / ShowTimelineView.zoomStep) }.keyboardShortcut("-", modifiers: .command)
            Button("") { stepPhoto(by: -1) }.keyboardShortcut(.leftArrow, modifiers: [])
            Button("") { stepPhoto(by: 1) }.keyboardShortcut(.rightArrow, modifiers: [])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private func chooseFiles(images: Bool) -> () -> Void {
        {
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = true
            panel.canChooseDirectories = true
            panel.allowedContentTypes = images ? [.image, .folder] : [.audio, .folder]
            panel.message = images ? "Choose photos, or folders of photos" : "Choose music"
            guard panel.runModal() == .OK else { return }
            if images {
                let after = show.slides.lastIndex { selection.contains($0.id) }
                addPhotos(panel.urls, at: after.map { $0 + 1 } ?? show.slides.count)
            } else {
                addAudio(panel.urls, at: show.audio.map(\.end).max() ?? 0)
            }
        }
    }

    private func addPhotos(_ urls: [URL], at index: Int) {
        let files = MediaStore.expand(urls, keeping: MediaStore.isImage)
        var updated = document
        let slides = updated.makeSlides(for: files)
        guard !slides.isEmpty else { NSSound.beep(); return }
        updated.insertSlides(slides, at: index)
        document = updated
        selection = Set(slides.map(\.id))
        currentID = slides.first?.id
    }

    private func addAudio(_ urls: [URL], at time: Double) {
        let files = MediaStore.expand(urls, keeping: MediaStore.isAudio)
        guard !files.isEmpty else { NSSound.beep(); return }
        Task {
            var durations: [(URL, Double)] = []
            for url in files {
                if let duration = await MediaStore.audioDuration(of: url) { durations.append((url, duration)) }
            }
            var updated = document
            var start = max(time, 0)
            for (url, duration) in durations {
                updated.show.audio.append(updated.makeAudioClip(for: url, duration: duration, at: start))
                start += duration
            }
            document = updated
        }
    }

    private func previewSlide(at index: Int) {
        let timeline = ShowTimeline(show: show)
        guard timeline.entries.indices.contains(index) else { return }
        mode = .preview
        playback.pause()
        playback.seek(to: timeline.entries[index].start)
        playback.play()
    }

    private func startExport() {
        playback.pause()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = (fileURL?.deletingPathExtension().lastPathComponent ?? "Slide Show") + ".mp4"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let exporter = VideoExporter(show: show, outputURL: url)
        let progress = ExportProgress(exporter: exporter, url: url)
        exporter.onProgress = { value in
            Task { @MainActor in progress.fraction = value }
        }
        export = progress
        Task {
            do {
                try await exporter.run()
                progress.finished = true
            } catch VideoExporter.Failure.cancelled {
                export = nil
            } catch {
                progress.error = error.localizedDescription
            }
        }
    }
}

/// What the music depends on; the preview's music is rebuilt when it changes.
private struct AudioKey: Hashable {
    var clips: [AudioClip]
    var fadeOut: Double
    var duration: Double
}

struct TransportBar: View {
    let playback: PlaybackController
    var togglePlay: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: togglePlay) {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 20)
            }
            .buttonStyle(.borderless)
            Text("\(formatTime(playback.time)) / \(formatTime(playback.duration))")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Slider(value: Binding(get: { playback.time }, set: { playback.seek(to: $0) }),
                   in: 0...max(playback.duration, 0.01))
            Divider().frame(height: 16)
            Image(systemName: "hare").foregroundStyle(.secondary)
            Slider(value: Binding(get: { playback.speed }, set: { playback.speed = $0.rounded() }),
                   in: 1...PlaybackController.maxSpeed, step: 1)
                .frame(width: 110)
                .help("Playback speed. [ slower, ] faster, \\ normal")
            Text("\(Int(playback.speed))×")
                .monospacedDigit()
                .frame(width: 24, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

/// A draggable bar that sets the height of the view below it.
struct SplitHandle: View {
    @Binding var height: Double
    let range: ClosedRange<Double>
    @State private var startHeight: Double?

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(height: 1)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .pointerStyle(.rowResize)
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let start = startHeight ?? min(max(height, range.lowerBound), range.upperBound)
                    startHeight = start
                    height = min(max(start - value.translation.height, range.lowerBound), range.upperBound)
                }
                .onEnded { _ in startHeight = nil })
    }
}

/// What the app's menu commands act on, for the frontmost document window.
struct ShowCommands {
    var playback: PlaybackController
    var zoomTimeline: (Double) -> Void
}

extension FocusedValues {
    @Entry var showCommands: ShowCommands?
}

func formatTime(_ seconds: Double) -> String {
    let s = max(seconds, 0)
    let minutes = Int(s) / 60
    return String(format: "%d:%04.1f", minutes, s - Double(minutes * 60))
}
