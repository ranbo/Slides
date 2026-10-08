import SwiftUI

struct SlideEditorView: View {
    @Binding var slide: Slide
    let index: Int
    let settings: ShowSettings
    var onCopyIntoDocument: () -> Void
    var onPreview: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            CropCanvas(slide: $slide, index: index, settings: settings)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            controls
                .padding(12)
                .background(.bar)
        }
    }

    private var controls: some View {
        HStack(alignment: .top, spacing: 28) {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Motion", selection: $slide.motion) {
                    Text("Zoom").tag(MotionKind.zoom)
                    Text("Pan").tag(MotionKind.pan)
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
                switch slide.motion {
                case .zoom: zoomControls
                case .pan: panControls
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Duration")
                    SecondsField(value: Binding(get: { slide.duration(settings) }, set: { slide.duration = $0 }),
                                 range: ShowTimeline.minimumDuration...120, step: 0.5)
                    if slide.duration != nil {
                        Button("Default") { slide.duration = nil }.controlSize(.small)
                    }
                }
                HStack {
                    Button("Fill Frame") { slide.crop = nil; slide.panStart = nil; slide.panEnd = nil }
                        .help("Crop to fill the frame, centered")
                    Button("Fit Whole Photo") {
                        slide.crop = FrameMath.fitRect(imageAspect: slide.imageAspect, outputAspect: settings.outputAspect)
                        slide.panStart = nil
                        slide.panEnd = nil
                    }
                    .help("Show the entire photo, with black bars")
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 10) {
                Button("Preview Slide", systemImage: "play.fill", action: onPreview)
                if slide.source.isEmbedded {
                    Label("Copied into document", systemImage: "doc.fill")
                        .foregroundStyle(.secondary)
                } else {
                    Button("Copy Into Document", action: onCopyIntoDocument)
                }
            }
        }
        .controlSize(.regular)
    }

    @ViewBuilder
    private var zoomControls: some View {
        Picker("Direction", selection: $slide.direction) {
            Text(index.isMultiple(of: 2) ? "Auto (In)" : "Auto (Out)").tag(ZoomDirection.auto)
            Text("Zoom In").tag(ZoomDirection.zoomIn)
            Text("Zoom Out").tag(ZoomDirection.zoomOut)
        }
        .frame(width: 220)
        HStack {
            Text("Zoom")
            CommitSlider(value: slide.zoomAmount(settings), range: 0...0.4) { slide.zoom = $0 }
                .frame(width: 140)
            Text("\(Int((slide.zoomAmount(settings) * 100).rounded()))%")
                .monospacedDigit()
                .frame(width: 36, alignment: .trailing)
            if slide.zoom != nil {
                Button("Default") { slide.zoom = nil }.controlSize(.small)
            }
        }
        Button("Center Focus") { slide.focus = nil }
            .disabled(slide.focus == nil)
            .help("Drag the crosshair to choose what the zoom moves toward")
    }

    @ViewBuilder
    private var panControls: some View {
        HStack {
            Button("Swap Start and End") {
                let rects = slide.panRects(settings)
                slide.panStart = rects.end
                slide.panEnd = rects.start
            }
            Button("Reset Pan") {
                slide.panStart = nil
                slide.panEnd = nil
            }
        }
    }
}

/// A slider that only writes its value when the drag ends, so each drag is one undo step.
struct CommitSlider: View {
    let value: Double
    let range: ClosedRange<Double>
    let commit: (Double) -> Void
    @State private var live: Double?

    var body: some View {
        Slider(value: Binding(get: { live ?? value }, set: { live = $0 }), in: range) { editing in
            if !editing, let live {
                commit(live)
                self.live = nil
            }
        }
    }
}

struct SecondsField: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step = 0.5

    var body: some View {
        HStack(spacing: 4) {
            TextField("", value: Binding(get: { value }, set: { value = min(max($0, range.lowerBound), range.upperBound) }),
                      format: .number.precision(.fractionLength(0...2)))
                .frame(width: 52)
                .multilineTextAlignment(.trailing)
            Stepper("", value: $value, in: range, step: step)
                .labelsHidden()
            Text("s").foregroundStyle(.secondary)
        }
    }
}

// MARK: - Crop canvas

/// Maps between normalized photo coordinates and view points.
private struct CanvasMapping {
    var origin: CGPoint
    var scale: CGSize

    /// Fits `box` (in normalized photo coordinates) into a view of `size`.
    init(size: CGSize, imageAspect: Double, box: NormRect, padding: CGFloat = 24) {
        let available = CGSize(width: max(size.width - 2 * padding, 10), height: max(size.height - 2 * padding, 10))
        let k = min(available.width / (box.width * imageAspect), available.height / box.height)
        scale = CGSize(width: k * imageAspect, height: k)
        let boxSize = CGSize(width: box.width * scale.width, height: box.height * scale.height)
        origin = CGPoint(x: (size.width - boxSize.width) / 2 - box.x * scale.width,
                         y: (size.height - boxSize.height) / 2 - box.y * scale.height)
    }

    func view(_ p: CGPoint) -> CGPoint {
        CGPoint(x: origin.x + p.x * scale.width, y: origin.y + p.y * scale.height)
    }

    func view(_ r: NormRect) -> CGRect {
        CGRect(x: origin.x + r.x * scale.width, y: origin.y + r.y * scale.height,
               width: r.width * scale.width, height: r.height * scale.height)
    }

    func norm(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - origin.x) / scale.width, y: (p.y - origin.y) / scale.height)
    }

    func normDelta(_ d: CGSize) -> CGSize {
        CGSize(width: d.width / scale.width, height: d.height / scale.height)
    }
}

private enum Corner: CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight

    var opposite: Corner {
        switch self {
        case .topLeft: .bottomRight
        case .topRight: .bottomLeft
        case .bottomLeft: .topRight
        case .bottomRight: .topLeft
        }
    }

    func point(in r: NormRect) -> CGPoint {
        CGPoint(x: self == .topLeft || self == .bottomLeft ? r.minX : r.maxX,
                y: self == .topLeft || self == .topRight ? r.minY : r.maxY)
    }

    func point(in r: CGRect) -> CGPoint {
        CGPoint(x: self == .topLeft || self == .bottomLeft ? r.minX : r.maxX,
                y: self == .topLeft || self == .topRight ? r.minY : r.maxY)
    }
}

/// Shows the photo with its crop and motion rectangles, which can be dragged and resized.
struct CropCanvas: View {
    @Binding var slide: Slide
    let index: Int
    let settings: ShowSettings

    private enum Target { case crop, panStart, panEnd }

    @State private var image: NSImage?
    /// The slide with an in-progress drag applied; written back when the drag ends.
    @State private var live: Slide?
    @State private var dragStart: NormRect?

    private var shown: Slide { live ?? slide }
    private var ratio: Double { slide.normalizedRatio(settings) }

    var body: some View {
        GeometryReader { geo in
            // Size the view from the committed slide so it doesn't shift during a drag.
            let committed = slide.panRects(settings)
            let box = NormRect.unit.union(slide.maxCrop(settings)).union(committed.start).union(committed.end)
            let map = CanvasMapping(size: geo.size, imageAspect: slide.imageAspect, box: box)
            let photoFrame = map.view(NormRect.unit)
            ZStack(alignment: .topLeading) {
                Group {
                    if let image {
                        Image(nsImage: image).resizable()
                    } else {
                        Rectangle().fill(.gray.opacity(0.25))
                    }
                }
                .frame(width: photoFrame.width, height: photoFrame.height)
                .position(x: photoFrame.midX, y: photoFrame.midY)

                switch shown.motion {
                case .zoom: zoomOverlay(map: map, size: geo.size)
                case .pan: panOverlay(map: map)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .coordinateSpace(name: "canvas")
        }
        .background(Color(white: 0.12))
        .clipped()
        .task(id: slide.source) {
            image = await ThumbnailCache.editor.image(for: slide.source)
        }
    }

    // MARK: Overlays

    @ViewBuilder
    private func zoomOverlay(map: CanvasMapping, size: CGSize) -> some View {
        let outer = shown.maxCrop(settings)
        let inner = shown.innerRect(settings)
        let zoomsIn = shown.zoomsIn(at: index)
        let outerRect = map.view(outer), innerRect = map.view(inner)

        Path { path in
            path.addRect(CGRect(origin: .zero, size: size))
            path.addRect(outerRect)
        }
        .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
        .allowsHitTesting(false)

        Rectangle()
            .stroke(Color.white, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            .frame(width: innerRect.width, height: innerRect.height)
            .position(x: innerRect.midX, y: innerRect.midY)
            .allowsHitTesting(false)
        label(zoomsIn ? "End" : "Start", color: .white, at: innerRect, alignment: .bottomTrailing)

        editableRect(outer, target: .crop, color: .yellow,
                     title: (zoomsIn ? "Start" : "End") + " · max crop", map: map)

        let focus = map.view(shown.focusPoint(settings))
        ZStack {
            Circle().stroke(Color.yellow, lineWidth: 2).frame(width: 22, height: 22)
            Rectangle().fill(Color.yellow).frame(width: 1.5, height: 30)
            Rectangle().fill(Color.yellow).frame(width: 30, height: 1.5)
        }
        .frame(width: 32, height: 32)
        .contentShape(Rectangle())
        .position(focus)
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("canvas"))
            .onChanged { value in
                var edited = shown
                edited.focus = edited.maxCrop(settings).clamping(map.norm(value.location))
                live = edited
            }
            .onEnded { _ in commit() })
        .help("Zoom focus: drag onto what the zoom should move toward")
    }

    @ViewBuilder
    private func panOverlay(map: CanvasMapping) -> some View {
        let rects = shown.panRects(settings)
        let start = map.view(rects.start), end = map.view(rects.end)
        Path { path in
            path.move(to: CGPoint(x: start.midX, y: start.midY))
            path.addLine(to: CGPoint(x: end.midX, y: end.midY))
        }
        .stroke(Color.white, style: StrokeStyle(lineWidth: 2, dash: [4, 4]))
        .allowsHitTesting(false)
        editableRect(rects.start, target: .panStart, color: .green, title: "Start", map: map)
        editableRect(rects.end, target: .panEnd, color: .orange, title: "End", map: map)
    }

    @ViewBuilder
    private func editableRect(_ rect: NormRect, target: Target, color: Color, title: String, map: CanvasMapping) -> some View {
        let r = map.view(rect)
        Rectangle()
            .stroke(color, lineWidth: 2)
            .background(Color.white.opacity(0.001))
            .frame(width: r.width, height: r.height)
            .position(x: r.midX, y: r.midY)
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("canvas"))
                .onChanged { value in
                    let start = beginDrag(target)
                    let d = map.normDelta(value.translation)
                    set(target, start.offsetBy(dx: d.width, dy: d.height))
                }
                .onEnded { _ in commit() })
        label(title, color: color, at: r, alignment: .topLeading)
        ForEach(Corner.allCases, id: \.self) { corner in
            Rectangle()
                .fill(color)
                .frame(width: 10, height: 10)
                .padding(5)
                .contentShape(Rectangle())
                .position(corner.point(in: r))
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("canvas"))
                    .onChanged { value in
                        let start = beginDrag(target)
                        set(target, .resized(anchor: corner.opposite.point(in: start),
                                             toward: map.norm(value.location), ratio: ratio))
                    }
                    .onEnded { _ in commit() })
        }
    }

    private func label(_ text: String, color: Color, at rect: CGRect, alignment: Alignment) -> some View {
        Text(text)
            .font(.caption.bold())
            .foregroundStyle(.black)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(color)
            .frame(width: rect.width, height: rect.height, alignment: alignment)
            .position(x: rect.midX, y: rect.midY)
            .allowsHitTesting(false)
    }

    // MARK: Dragging

    private func rect(_ target: Target, of s: Slide) -> NormRect {
        switch target {
        case .crop: s.maxCrop(settings)
        case .panStart: s.panRects(settings).start
        case .panEnd: s.panRects(settings).end
        }
    }

    private func beginDrag(_ target: Target) -> NormRect {
        if let dragStart { return dragStart }
        let start = rect(target, of: shown)
        dragStart = start
        return start
    }

    private func set(_ target: Target, _ rect: NormRect) {
        var edited = shown
        switch target {
        case .crop: edited.crop = rect
        case .panStart: edited.panStart = rect
        case .panEnd: edited.panEnd = rect
        }
        live = edited
    }

    private func commit() {
        if let live { slide = live }
        live = nil
        dragStart = nil
    }
}
