import SwiftUI

@main
struct SlidesApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: SlideShowDocument()) { file in
            ContentView(document: file.$document, fileURL: file.fileURL)
                .frame(minWidth: 960, minHeight: 640)
        }
        .defaultSize(width: 1400, height: 900)
    }
}
