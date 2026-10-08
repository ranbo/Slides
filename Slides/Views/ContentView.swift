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

    private var show: SlideShow { document.show }

    var body: some View {
        let timeline = ShowTimeline(show: show)
        VSplitView {
            HSplitView {
                PhotoGridView(document: $document, selection: $selection, currentID: $currentID,
                              onAddPhotos: addPhotos)
                    .frame(minWidth: 240, idealWidth: 380)
                mainPane
                    .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(minHeight: 360, maxHeight: .infinity)
            ShowTimelineView(document: $document, selection: $selection, currentID: $currentID,
                             playback: playback, onSeek: { mode = .preview }, onAddAudio: addAudio)
                .frame(minHeight: 170, idealHeight: 210, maxHeight: 400)
        }
        .toolbar { toolbar }
        .sheet(item: $export) { progress in
            ExportSheet(progress: progress) { export = nil }
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
                SlideEditorView(slide: $document.show.slides[index], index: index, settings: show.settings,
                                onCopyIntoDocument: { document.embedMedia(slideIDs: [show.slides[index].id], clipIDs: []) },
                                onPreview: { previewSlide(at: index) })
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
                TransportBar(playback: playback)
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
                   systemImage: playback.isPlaying ? "pause.fill" : "play.fill") {
                mode = .preview
                playback.togglePlay()
            }
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

    // MARK: - Actions

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

    var body: some View {
        HStack(spacing: 12) {
            Button {
                playback.togglePlay()
            } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 20)
            }
            .buttonStyle(.borderless)
            Text("\(formatTime(playback.time)) / \(formatTime(playback.duration))")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Slider(value: Binding(get: { playback.time }, set: { playback.seek(to: $0) }),
                   in: 0...max(playback.duration, 0.01))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

func formatTime(_ seconds: Double) -> String {
    let s = max(seconds, 0)
    let minutes = Int(s) / 60
    return String(format: "%d:%04.1f", minutes, s - Double(minutes * 60))
}
