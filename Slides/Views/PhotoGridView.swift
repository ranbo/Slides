import SwiftUI
import UniformTypeIdentifiers

/// Where a drag would drop: before or after a slide.
struct DropMarker: Equatable {
    var id: UUID
    var after: Bool
}

struct PhotoGridView: View {
    @Binding var document: SlideShowDocument
    @Binding var selection: Set<UUID>
    @Binding var currentID: UUID?
    var onAddPhotos: (_ urls: [URL], _ index: Int) -> Void

    @State private var anchorID: UUID?
    @State private var draggedIDs: Set<UUID> = []
    @State private var marker: DropMarker?
    @FocusState private var focused: Bool

    private static let internalDragToken = "com.ranbo.slides.internal-drag"

    private var slides: [Slide] { document.show.slides }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 260), spacing: 12)], spacing: 12) {
                ForEach(Array(slides.enumerated()), id: \.element.id) { index, slide in
                    GridCell(slide: slide, index: index, settings: document.show.settings,
                             isSelected: selection.contains(slide.id), marker: marker)
                        .onTapGesture { click(slide.id) }
                        .onDrag {
                            draggedIDs = selection.contains(slide.id) ? selection : [slide.id]
                            return NSItemProvider(object: Self.internalDragToken as NSString)
                        }
                        .contextMenu { contextMenu(for: slide) }
                        .modifier(CellDropTarget(id: slide.id, marker: $marker, perform: drop))
                }
            }
            .padding(12)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay {
            if slides.isEmpty {
                ContentUnavailableView("Drag Photos Here", systemImage: "photo.stack",
                                       description: Text("Or use the + button in the toolbar."))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { selection = []; focused = true }
        .onDrop(of: [.plainText, .fileURL], isTargeted: nil) { providers in
            drop(providers, target: nil)
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onDeleteCommand(perform: deleteSelection)
        .onCopyCommand(perform: clipboardItems)
        .onCutCommand {
            let items = clipboardItems()
            deleteSelection()
            return items
        }
        .onPasteCommand(of: [.slideClipboard, .fileURL], perform: paste)
        .onCommand(#selector(NSResponder.selectAll(_:))) { selection = Set(slides.map(\.id)) }
    }

    // MARK: - Selection

    private func click(_ id: UUID) {
        focused = true
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            anchorID = id
        } else if flags.contains(.shift), let anchorID,
                  let a = slides.firstIndex(where: { $0.id == anchorID }),
                  let b = slides.firstIndex(where: { $0.id == id }) {
            selection = Set(slides[min(a, b)...max(a, b)].map(\.id))
        } else {
            selection = [id]
            anchorID = id
        }
        currentID = id
    }

    /// Selected slides in show order.
    private var selectedSlides: [Slide] {
        slides.filter { selection.contains($0.id) }
    }

    // MARK: - Editing

    private func deleteSelection() {
        guard !selection.isEmpty else { return }
        let firstIndex = slides.firstIndex { selection.contains($0.id) } ?? 0
        document.removeSlides(selection)
        let next = slides.indices.contains(firstIndex) ? slides[firstIndex] : slides.last
        selection = next.map { [$0.id] } ?? []
        currentID = next?.id
    }

    private func clipboardItems() -> [NSItemProvider] {
        guard let data = try? JSONEncoder().encode(selectedSlides), !selection.isEmpty else { return [] }
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.slideClipboard.identifier, visibility: .all) { completion in
            completion(data, nil)
            return nil
        }
        return [provider]
    }

    /// Pastes after the last selected slide, or at the end.
    private func paste(_ providers: [NSItemProvider]) {
        let index = (slides.lastIndex { selection.contains($0.id) }).map { $0 + 1 } ?? slides.count
        if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.slideClipboard.identifier) }) {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.slideClipboard.identifier) { data, _ in
                guard let data, let pasted = try? JSONDecoder().decode([Slide].self, from: data) else { return }
                DispatchQueue.main.async { insertCopies(of: pasted, at: index) }
            }
        } else {
            ItemProviderLoader.fileURLs(from: providers) { urls in onAddPhotos(urls, index) }
        }
    }

    private func insertCopies(of pasted: [Slide], at index: Int) {
        let copies = pasted.map { slide -> Slide in
            var copy = slide
            copy.id = UUID()
            return copy
        }
        document.insertSlides(copies, at: index)
        selection = Set(copies.map(\.id))
        currentID = copies.first?.id
    }

    /// Handles a drop on a slide (or on empty space when `target` is nil).
    private func drop(_ providers: [NSItemProvider], target: DropMarker?) -> Bool {
        marker = nil
        let index: Int = {
            guard let target, let i = slides.firstIndex(where: { $0.id == target.id }) else { return slides.count }
            return target.after ? i + 1 : i
        }()
        if !draggedIDs.isEmpty, providers.contains(where: { $0.canLoadObject(ofClass: NSString.self) }),
           !providers.contains(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) {
            document.moveSlides(draggedIDs, to: target?.id, after: target?.after ?? true)
            draggedIDs = []
            return true
        }
        draggedIDs = []
        ItemProviderLoader.fileURLs(from: providers) { urls in onAddPhotos(urls, index) }
        return true
    }

    @ViewBuilder
    private func contextMenu(for slide: Slide) -> some View {
        let ids = selection.contains(slide.id) ? selection : [slide.id]
        Button("Delete") {
            selection = ids
            deleteSelection()
        }
        Button("Copy Into Document") { document.embedMedia(slideIDs: ids, clipIDs: []) }
            .disabled(slides.filter { ids.contains($0.id) }.allSatisfy(\.source.isEmbedded))
        if case .file = slide.source, let url = MediaStore.url(for: slide.source) {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
        Divider()
        Button("Reset Duration") {
            for i in document.show.slides.indices where ids.contains(document.show.slides[i].id) {
                document.show.slides[i].duration = nil
            }
        }
    }
}

/// Tracks whether a drag is over the left or right half of a cell.
private struct CellDropTarget: ViewModifier {
    let id: UUID
    @Binding var marker: DropMarker?
    let perform: ([NSItemProvider], DropMarker?) -> Bool
    @State private var width: CGFloat = 1

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .onDrop(of: [.plainText, .fileURL], delegate: Delegate(target: self))
    }

    struct Delegate: DropDelegate {
        let target: CellDropTarget

        private func marker(_ info: DropInfo) -> DropMarker {
            DropMarker(id: target.id, after: info.location.x > target.width / 2)
        }

        func dropUpdated(info: DropInfo) -> DropProposal? {
            target.marker = marker(info)
            return DropProposal(operation: info.hasItemsConforming(to: [.fileURL]) ? .copy : .move)
        }

        func dropExited(info: DropInfo) {
            if target.marker?.id == target.id { target.marker = nil }
        }

        func performDrop(info: DropInfo) -> Bool {
            target.perform(info.itemProviders(for: [.plainText, .fileURL]), marker(info))
        }
    }
}

private struct GridCell: View {
    let slide: Slide
    let index: Int
    let settings: ShowSettings
    let isSelected: Bool
    let marker: DropMarker?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            CroppedThumbnail(slide: slide, settings: settings)
                .overlay(alignment: .topLeading) {
                    Text("\(index + 1)")
                        .font(.caption.bold().monospacedDigit())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.black.opacity(0.6), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(4)
                }
                .overlay(alignment: .bottomTrailing) {
                    HStack(spacing: 4) {
                        if slide.source.isEmbedded { Image(systemName: "doc.fill").help("Copied into the document") }
                        Image(systemName: motionSymbol).help(motionHelp)
                        Text(String(format: "%.1fs", slide.duration(settings)))
                            .fontWeight(slide.duration == nil ? .regular : .bold)
                    }
                    .font(.caption2.monospacedDigit())
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.6), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(4)
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 3)
                }
            Text(slide.name)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(isSelected ? .primary : .secondary)
        }
        .padding(4)
        .background(isSelected ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: marker?.after == true ? .trailing : .leading) {
            if marker?.id == slide.id {
                Capsule().fill(Color.accentColor).frame(width: 4).offset(x: marker!.after ? 8 : -8)
            }
        }
        .contentShape(Rectangle())
    }

    private var motionSymbol: String {
        switch slide.motion {
        case .pan: "arrow.left.and.right"
        case .zoom: slide.zoomsIn(at: index) ? "plus.magnifyingglass" : "minus.magnifyingglass"
        }
    }

    private var motionHelp: String {
        switch slide.motion {
        case .pan: "Pans"
        case .zoom: slide.zoomsIn(at: index) ? "Zooms in" : "Zooms out"
        }
    }
}

/// The photo shown through its maximum crop, at the output's aspect ratio.
struct CroppedThumbnail: View {
    let slide: Slide
    let settings: ShowSettings
    @State private var image: NSImage?
    @State private var missing = false

    var body: some View {
        Color.black
            .aspectRatio(settings.outputAspect, contentMode: .fit)
            .overlay(alignment: .topLeading) {
                GeometryReader { geo in
                    if let image {
                        let crop = slide.maxCrop(settings)
                        let width = geo.size.width / crop.width
                        let height = geo.size.height / crop.height
                        Image(nsImage: image)
                            .resizable()
                            .frame(width: width, height: height)
                            .offset(x: -crop.x * width, y: -crop.y * height)
                    } else if missing {
                        Label("Missing", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                            .frame(width: geo.size.width, height: geo.size.height)
                    }
                }
            }
            .clipped()
            .task(id: slide.source) {
                image = await ThumbnailCache.grid.image(for: slide.source)
                missing = image == nil
            }
    }
}
