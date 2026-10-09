import SwiftUI

/// How the app works, and its keyboard shortcuts. Shown in a floating window from the Help menu.
struct HelpView: View {
    static let windowID = "help"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Slides turns a list of photos into a Ken Burns slide show: each photo slowly zooms or pans, cross-fades into the next, and plays over your music. Export it as a 1080p movie.")
                    .fixedSize(horizontal: false, vertical: true)

                section("Getting Started", [
                    ("Add photos", "Drag photos or folders into the photo list, or use the Add Photos toolbar button."),
                    ("Add music", "Drag music onto the timeline, or use the Add Music toolbar button."),
                    ("Edit", "Select a photo to set its crop, zoom and focus. Changes apply to every selected photo."),
                    ("Preview", "Press Space to play from the photo you're editing. Space again stops, back on the photo that was showing."),
                    ("Export", "The Export toolbar button makes an MP4 movie."),
                ])

                section("How Photos Move", [
                    ("Outer rectangle", "Yellow: the most of the photo that's ever shown. It always has the movie's shape."),
                    ("Inner rectangle", "White: the outer one shrunk by the zoom amount (5% unless you change it), toward the focus point."),
                    ("Zoom in and out", "Photos take turns zooming in and out, by position in the show. Adding, removing or moving photos never needs fixing up. A photo can be set to always zoom in or out."),
                    ("Pan", "Set Motion to Pan to glide from one rectangle to another instead."),
                    ("Cross-fades", "Each photo fades into the next (0.5 seconds unless you change it in Settings)."),
                ])

                section("Editing a Photo", [
                    ("Drag inside", "Move the outer rectangle."),
                    ("Shift-drag inside", "Move the inner rectangle."),
                    ("Drag a corner or side", "Resize a rectangle. Option-drag resizes it about its center."),
                    ("Scroll", "Make the outer rectangle bigger or smaller."),
                    ("Drag the crosshair", "Set the focus point: what the zoom closes in on."),
                    ("Fill Frame / Fit Whole Photo", "Crop to fill the movie frame, or show the whole photo with black bars."),
                    ("Trim Borders", "Crop off the white border of scanned prints."),
                    ("Find Faces", "Aim the zoom at the faces in the photo. New photos get this automatically."),
                ])

                section("Photos Menu", [
                    ("Trim White Borders", "Trims the selected photos. With several selected, photos you've already cropped are left alone."),
                    ("Find Faces", "Sets the focus point of the selected photos to their faces."),
                ], note: "Tip: trim borders before finding faces, since trimming can move the faces in the frame.")

                section("Timeline", [
                    ("Click the ruler", "Move the playhead. Drag to scrub."),
                    ("Drag a photo", "Move it (or all the selected photos) to a new place in the show."),
                    ("Drag a photo's right edge", "Change how long it's shown (4 seconds unless you change it)."),
                    ("Drag music", "Move it. Drag its ends to trim it. The waveform shows loud and quiet parts, to help pick where to cut."),
                    ("Double-click music", "Edit its gain and fades (or click it while in Edit mode). A trimmed end fades out over 0.5 seconds unless you change it; an untrimmed end doesn't fade."),
                    ("⌘B", "Split the music at the playhead into two clips, then drag either end or delete the half you don't want."),
                    ("Double-click a photo", "Edit it. This works in the photo list too."),
                ])

                shortcuts
            }
            .padding(20)
        }
        .frame(minWidth: 460, idealWidth: 540, minHeight: 400, idealHeight: 720)
    }

    private var shortcuts: some View {
        section("Keyboard Shortcuts", [
            ("Space", "Play or stop"),
            ("← →", "Previous or next photo"),
            ("[  ]", "Play slower or faster (up to 8×)"),
            ("\\", "Play at normal speed"),
            ("-  =  (or ⌘-  ⌘=)", "Zoom the timeline out or in"),
            ("Click", "Select one photo or music clip"),
            ("⌘-click", "Add to or remove from the selection"),
            ("Shift-click", "Select a run of photos"),
            ("⌘A", "Select all photos (or all music, if music is selected)"),
            ("Delete", "Remove the selected photos or music"),
            ("⌘B", "Split the music at the playhead"),
            ("⌘X  ⌘C  ⌘V", "Cut, copy and paste photos in the photo list"),
            ("⌘Z  ⇧⌘Z", "Undo and redo"),
        ])
    }

    private func section(_ title: String, _ rows: [(String, String)], note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.title3.bold())
            Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 6) {
                ForEach(rows, id: \.0) { key, text in
                    GridRow {
                        Text(key)
                            .fontWeight(.semibold)
                            .frame(width: 170, alignment: .leading)
                        Text(text)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let note {
                Text(note).font(.callout).italic().foregroundStyle(.secondary)
            }
        }
    }
}

/// Help > Slides Help (⌘?) opens the help window.
struct HelpCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Slides Help") { openWindow(id: HelpView.windowID) }
                .keyboardShortcut("?", modifiers: .command)
        }
    }
}
