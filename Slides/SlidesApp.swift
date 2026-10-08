import SwiftUI

@main
struct SlidesApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: SlideShowDocument()) { file in
            ContentView(document: file.$document, fileURL: file.fileURL)
                .frame(minWidth: 960, minHeight: 640)
        }
        .defaultSize(width: 1400, height: 900)
        .commands { ShowMenuCommands() }
    }
}

/// Playback speed and timeline zoom, for the frontmost document window.
struct ShowMenuCommands: Commands {
    @FocusedValue(\.showCommands) private var show

    var body: some Commands {
        CommandMenu("Playback") {
            Button("Slower") { show?.playback.changeSpeed(by: -1) }
                .keyboardShortcut("[", modifiers: [])
            Button("Faster") { show?.playback.changeSpeed(by: 1) }
                .keyboardShortcut("]", modifiers: [])
            Button("Normal Speed") { show?.playback.speed = 1 }
                .keyboardShortcut("\\", modifiers: [])
        }
        CommandMenu("Photos") {
            Group {
                Button("Trim White Borders") { show?.trimBorders() }
                Button("Find Faces") { show?.findFaces() }
            }
            .disabled(show?.hasPhotoSelection != true)
        }
        CommandGroup(after: .toolbar) {
            Button("Zoom In Timeline") { show?.zoomTimeline(ShowTimelineView.zoomStep) }
                .keyboardShortcut("=", modifiers: [])
            Button("Zoom Out Timeline") { show?.zoomTimeline(1 / ShowTimelineView.zoomStep) }
                .keyboardShortcut("-", modifiers: [])
            Divider()
        }
    }
}
