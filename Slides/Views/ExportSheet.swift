import SwiftUI

@MainActor @Observable
final class ExportProgress: Identifiable {
    let exporter: VideoExporter
    let url: URL
    var fraction = 0.0
    var finished = false
    var error: String?

    init(exporter: VideoExporter, url: URL) {
        self.exporter = exporter
        self.url = url
    }
}

struct ExportSheet: View {
    let progress: ExportProgress
    var dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            Text(progress.url.lastPathComponent).foregroundStyle(.secondary)
            if let error = progress.error {
                Text(error).foregroundStyle(.red)
            } else {
                ProgressView(value: progress.finished ? 1 : progress.fraction)
            }
            HStack {
                Spacer()
                if progress.finished {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([progress.url])
                        dismiss()
                    }
                    Button("Done", action: dismiss).keyboardShortcut(.defaultAction)
                } else if progress.error != nil {
                    Button("Close", action: dismiss).keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel") { progress.exporter.cancel() }.keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private var title: String {
        if progress.finished { return "Export Complete" }
        if progress.error != nil { return "Export Failed" }
        return "Exporting Movie…"
    }
}
