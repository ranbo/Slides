import SwiftUI

struct SlideEditorView: View {
    @Binding var slide: Slide
    let index: Int
    let settings: ShowSettings
    /// How many photos the controls below the picture change (the selection, if it includes this photo).
    let editCount: Int
    /// Whether every photo being edited is already copied into the document.
    let allEmbedded: Bool
    /// Applies a change to every photo being edited, as one undo step.
    var apply: ((inout Slide) -> Void) -> Void
    var onCopyIntoDocument: () -> Void
    var onPreview: () -> Void

    private var multiple: Bool { editCount > 1 }

    var body: some View {
        VStack(spacing: 0) {
            CropCanvas(slide: $slide, index: index, settings: settings)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            if multiple {
                Label("Changes below apply to all \(editCount) selected photos. Dragging in the picture changes only this one.",
                      systemImage: "square.stack.3d.up")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .background(.bar)
            }
            controls
                .padding(12)
                .background(.bar)
        }
    }

    /// A binding that shows this photo's value and writes to every photo being edited.
    private func binding<Value>(_ keyPath: WritableKeyPath<Slide, Value>) -> Binding<Value> {
        Binding(get: { slide[keyPath: keyPath] }, set: { value in apply { $0[keyPath: keyPath] = value } })
    }

    private var controls: some View {
        HStack(alignment: .top, spacing: 28) {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Motion", selection: binding(\.motion)) {
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
                    SecondsField(value: Binding(get: { slide.duration(settings) }, set: { value in apply { $0.duration = value } }),
                                 range: ShowTimeline.minimumDuration...120, step: 0.5)
                    if multiple || slide.duration != nil {
                        Button("Default") { apply { $0.duration = nil } }.controlSize(.small).fixedSize()
                    }
                }
                HStack {
                    Button("Fill Frame") {
                        apply { $0.crop = nil; $0.panStart = nil; $0.panEnd = nil }
                    }
                    .help("Crop to fill the frame, centered")
                    Button("Fit Whole Photo") {
                        apply {
                            $0.crop = FrameMath.fitRect(imageAspect: $0.imageAspect, outputAspect: settings.outputAspect)
                            $0.panStart = nil
                            $0.panEnd = nil
                        }
                    }
                    .help("Show the entire photo, with black bars")
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 10) {
                Button("Preview Slide", systemImage: "play.fill", action: onPreview)
                if allEmbedded {
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
        Picker("Direction", selection: binding(\.direction)) {
            Text(multiple ? "Auto (alternate)" : index.isMultiple(of: 2) ? "Auto (In)" : "Auto (Out)").tag(ZoomDirection.auto)
            Text("Zoom In").tag(ZoomDirection.zoomIn)
            Text("Zoom Out").tag(ZoomDirection.zoomOut)
        }
        .frame(width: 220)
        HStack {
            Text("Zoom").fixedSize()
            CommitSlider(value: slide.zoomAmount(settings), range: 0...0.4) { value in apply { $0.zoom = value } }
                .frame(width: 140)
            Text("\(Int((slide.zoomAmount(settings) * 100).rounded()))%")
                .monospacedDigit()
                .frame(width: 36, alignment: .trailing)
            if multiple || slide.zoom != nil {
                Button("Default") { apply { $0.zoom = nil; $0.focus = nil } }
                    .controlSize(.small)
                    .fixedSize()
                    .help("Use the default zoom, centered")
            }
        }
        Button("Center Focus") { apply { $0.focus = nil } }
            .disabled(!multiple && slide.focus == nil)
            .help("Drag the crosshair to choose what the zoom closes in on. Shift-drag in the picture to move the inner rectangle.")
    }

    @ViewBuilder
    private var panControls: some View {
        HStack {
            Button("Swap Start and End") {
                apply {
                    let rects = $0.panRects(settings)
                    $0.panStart = rects.end
                    $0.panEnd = rects.start
                }
            }
            Button("Reset Pan") {
                apply { $0.panStart = nil; $0.panEnd = nil }
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

    /// The corner's point, pushed `outset` points away from the rectangle (negative pulls it inside).
    func point(in r: CGRect, outset: CGFloat = 0) -> CGPoint {
        let left = self == .topLeft || self == .bottomLeft
        let top = self == .topLeft || self == .topRight
        return CGPoint(x: left ? r.minX - outset : r.maxX + outset,
                       y: top ? r.minY - outset : r.maxY + outset)
    }
}

/// The middle of one side of a rectangle; dragging it moves the whole side.
private enum Side: CaseIterable {
    case top, bottom, left, right

    var isVertical: Bool { self == .left || self == .right }

    var resizePosition: FrameResizePosition {
        switch self {
        case .top: .top
        case .bottom: .bottom
        case .left: .leading
        case .right: .trailing
        }
    }

    /// The side's midpoint, pushed `outset` points away from the rectangle (negative pulls it inside).
    func point(in r: CGRect, outset: CGFloat) -> CGPoint {
        switch self {
        case .top: CGPoint(x: r.midX, y: r.minY - outset)
        case .bottom: CGPoint(x: r.midX, y: r.maxY + outset)
        case .left: CGPoint(x: r.minX - outset, y: r.midY)
        case .right: CGPoint(x: r.maxX + outset, y: r.midY)
        }
    }

    /// Moves this side to the pointer, keeping the opposite side fixed (or, if `symmetric`,
    /// moving it the other way). The rectangle keeps its shape, centered along the side.
    /// Returns the new rectangle and the point that stays put.
    func resized(_ start: NormRect, toward p: CGPoint, ratio: Double, symmetric: Bool,
                 minHeight: Double = 0.05) -> (NormRect, CGPoint) {
        let c = start.center
        if isVertical {
            let fixed = symmetric ? c.x : (self == .left ? start.maxX : start.minX)
            let w = max(abs(p.x - fixed) * (symmetric ? 2 : 1), minHeight * ratio)
            let x = symmetric ? c.x - w / 2 : (p.x >= fixed ? fixed : fixed - w)
            return (NormRect(x: x, y: c.y - w / ratio / 2, width: w, height: w / ratio), CGPoint(x: fixed, y: c.y))
        } else {
            let fixed = symmetric ? c.y : (self == .top ? start.maxY : start.minY)
            let h = max(abs(p.y - fixed) * (symmetric ? 2 : 1), minHeight)
            let y = symmetric ? c.y - h / 2 : (p.y >= fixed ? fixed : fixed - h)
            return (NormRect(x: c.x - h * ratio / 2, y: y, width: h * ratio, height: h), CGPoint(x: c.x, y: fixed))
        }
    }
}

/// Shows the photo with its crop and motion rectangles, which can be dragged and resized.
struct CropCanvas: View {
    @Binding var slide: Slide
    let index: Int
    let settings: ShowSettings

    private enum Target { case crop, inner, panStart, panEnd }

    @State private var image: NSImage?
    /// The slide with an in-progress drag applied; written back when the drag ends.
    @State private var live: Slide?
    @State private var dragStart: NormRect?
    /// Which rectangle the current move drag is moving, fixed when the drag starts.
    @State private var dragTarget: Target?
    /// Commits scroll-wheel resizing once scrolling pauses, so a burst of scrolling is one undo step.
    @State private var scrollCommit: Task<Void, Never>?

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
            .background {
                ScrollWheelCatcher { delta, location in scrollResize(delta: delta, at: location, map: map) }
            }
        }
        .background(Color(white: 0.12))
        .clipped()
        .task(id: slide.source) {
            image = await ThumbnailCache.editor.image(for: slide.source)
        }
        .onDisappear {
            // Save any edit still waiting (e.g. just after scrolling) before moving on.
            scrollCommit?.cancel()
            commit()
        }
    }

    // MARK: Overlays

    @ViewBuilder
    private func zoomOverlay(map: CanvasMapping, size: CGSize) -> some View {
        let outer = shown.maxCrop(settings)
        let inner = shown.innerRect(settings)
        let zoomsIn = shown.zoomsIn(at: index)
        let outerRect = map.view(outer)

        Path { path in
            path.addRect(CGRect(origin: .zero, size: size))
            path.addRect(outerRect)
        }
        .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
        .allowsHitTesting(false)

        // Dragging inside moves the outer rectangle (Shift-drag moves the inner one). The two
        // sets of corner handles sit outside and inside their rectangles so they don't collide.
        editableRect(outer, target: .crop, color: .yellow,
                     title: (zoomsIn ? "Start" : "End") + " · max crop", map: map,
                     shiftTarget: .inner, handleOutset: 7, edgeGrab: 10, titleOutside: true)
        editableRect(inner, target: .inner, color: .white, title: zoomsIn ? "End" : "Start", map: map,
                     movable: false, handleOutset: -7, titleAlignment: .bottomTrailing)

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
    /// A rectangle that resizes from its corner handles and, if `movable`, moves when dragged.
    /// `edgeGrab` widens the draggable area past the edge; `handleOutset` moves the handles
    /// outside (positive) or inside (negative) the corners. `shiftTarget` is moved instead
    /// when Shift is held as the drag starts.
    private func editableRect(_ rect: NormRect, target: Target, color: Color, title: String, map: CanvasMapping,
                              movable: Bool = true, shiftTarget: Target? = nil,
                              handleOutset: CGFloat = 0, edgeGrab: CGFloat = 0,
                              titleAlignment: Alignment = .topLeading, titleOutside: Bool = false) -> some View {
        let r = map.view(rect)
        Rectangle()
            .stroke(color, lineWidth: 2)
            .frame(width: r.width, height: r.height)
            .padding(edgeGrab)
            .contentShape(Rectangle())
            .position(x: r.midX, y: r.midY)
            .allowsHitTesting(movable)
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("canvas"))
                .onChanged { value in
                    let moving = dragTarget ?? (NSEvent.modifierFlags.contains(.shift) ? shiftTarget ?? target : target)
                    dragTarget = moving
                    let start = beginDrag(moving)
                    let d = map.normDelta(value.translation)
                    set(moving, start.offsetBy(dx: d.width, dy: d.height))
                }
                .onEnded { _ in commit() })
        // Inside labels stay clear of the corner handles.
        label(title, color: color, at: titleOutside ? r.offsetBy(dx: 0, dy: -18) : r.insetBy(dx: 20, dy: 0),
              alignment: titleAlignment)
        ForEach(Corner.allCases, id: \.self) { corner in
            Rectangle()
                .fill(color)
                .frame(width: 10, height: 10)
                .padding(4)
                .contentShape(Rectangle())
                .position(corner.point(in: r, outset: handleOutset))
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("canvas"))
                    .onChanged { value in
                        let start = beginDrag(target)
                        let pointer = map.norm(value.location)
                        if NSEvent.modifierFlags.contains(.option) {
                            // Resize about the center: all four corners move together.
                            let center = start.center
                            let corner = CGPoint(x: 2 * center.x - pointer.x, y: 2 * center.y - pointer.y)
                            let sized = NormRect.resized(anchor: corner, toward: pointer, ratio: ratio)
                            set(target, NormRect(center: center, width: sized.width, height: sized.height), anchor: center)
                        } else {
                            let anchor = corner.opposite.point(in: start)
                            set(target, .resized(anchor: anchor, toward: pointer, ratio: ratio), anchor: anchor)
                        }
                    }
                    .onEnded { _ in commit() })
        }
        ForEach(Side.allCases, id: \.self) { side in
            Capsule()
                .fill(color)
                .frame(width: side.isVertical ? 5 : 18, height: side.isVertical ? 18 : 5)
                .padding(4)
                .contentShape(Rectangle())
                .position(side.point(in: r, outset: handleOutset))
                .pointerStyle(.frameResize(position: side.resizePosition))
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("canvas"))
                    .onChanged { value in
                        let start = beginDrag(target)
                        let symmetric = NSEvent.modifierFlags.contains(.option)
                        let (rect, anchor) = side.resized(start, toward: map.norm(value.location),
                                                          ratio: ratio, symmetric: symmetric)
                        set(target, rect, anchor: anchor)
                    }
                    .onEnded { _ in commit() })
        }
    }

    private func label(_ text: String, color: Color, at rect: CGRect, alignment: Alignment) -> some View {
        Text(text)
            .font(.caption.bold())
            .fixedSize()
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
        case .inner: s.innerRect(settings)
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

    /// `anchor` is the point that stays put while resizing.
    private func set(_ target: Target, _ rect: NormRect, anchor: CGPoint? = nil) {
        var edited = shown
        let constrained = FrameMath.constrained(rect, imageAspect: slide.imageAspect,
                                                outputAspect: settings.outputAspect, anchor: anchor)
        switch target {
        case .crop: edited.crop = constrained
        case .inner: setInner(rect, of: &edited)
        case .panStart: edited.panStart = constrained
        case .panEnd: edited.panEnd = constrained
        }
        live = edited
    }

    /// The inner rectangle is the outer one scaled about the focus point, so a new inner
    /// rectangle (kept inside the outer one) translates exactly into a zoom amount and focus.
    private func setInner(_ proposed: NormRect, of s: inout Slide) {
        let outer = s.maxCrop(settings)
        let scale = min(max(proposed.width / outer.width, 0.1), 1)
        let width = outer.width * scale, height = outer.height * scale
        let x = min(max(proposed.x, outer.minX), outer.maxX - width)
        let y = min(max(proposed.y, outer.minY), outer.maxY - height)
        s.zoom = 1 - scale
        if scale < 0.999 {
            s.focus = CGPoint(x: (x - scale * outer.x) / (1 - scale), y: (y - scale * outer.y) / (1 - scale))
        }
    }

    /// Scrolling over the picture scales the crop (or, when panning, the rectangle under the
    /// pointer) about the pointer. Positive `delta` zooms in.
    private func scrollResize(delta: Double, at location: CGPoint, map: CanvasMapping) {
        let point = map.norm(location)
        let target: Target
        switch shown.motion {
        case .zoom:
            target = .crop
        case .pan:
            // The end rectangle is drawn on top, so it wins where they overlap.
            let rects = shown.panRects(settings)
            target = rects.end.clamping(point) == point ? .panEnd : rects.start.clamping(point) == point ? .panStart : .panEnd
        }
        let current = rect(target, of: shown)
        var scale = exp(-delta)
        if current.height * scale < 0.05 { scale = 0.05 / current.height }
        let anchor = current.clamping(point)
        set(target, current.scaled(by: scale, about: anchor), anchor: anchor)

        scrollCommit?.cancel()
        scrollCommit = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            commit()
        }
    }

    private func commit() {
        if let live { slide = live }
        live = nil
        dragStart = nil
        dragTarget = nil
    }
}

/// Reports scroll-wheel and trackpad scrolling over this view, with the location measured
/// from the view's top-left. The scroll is consumed so nothing else scrolls.
private struct ScrollWheelCatcher: NSViewRepresentable {
    var onScroll: (_ delta: Double, _ location: CGPoint) -> Void

    func makeNSView(context: Context) -> CatcherView {
        CatcherView()
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onScroll = onScroll
    }

    final class CatcherView: NSView {
        var onScroll: ((Double, CGPoint) -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, event.window === self.window else { return event }
                let p = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(p), event.scrollingDeltaY != 0 else { return event }
                // A mouse wheel reports lines; a trackpad reports many small pixel steps.
                let delta = event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.004 : 0.05)
                self.onScroll?(delta, CGPoint(x: p.x, y: self.isFlipped ? p.y : self.bounds.height - p.y))
                return nil
            }
        }
    }
}
