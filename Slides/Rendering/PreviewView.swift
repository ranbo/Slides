import CoreImage
import MetalKit
import SwiftUI

/// Live preview of the show, drawn with Metal at the display's frame rate.
struct PreviewView: NSViewRepresentable {
    var show: SlideShow
    var playback: PlaybackController

    func makeCoordinator() -> Coordinator {
        Coordinator(playback: playback)
    }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: context.coordinator.device)
        view.framebufferOnly = false
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.preferredFramesPerSecond = 60
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.update(show: show)
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        let device = MTLCreateSystemDefaultDevice()
        private let playback: PlaybackController
        private let commandQueue: MTLCommandQueue?
        private let context: CIContext
        private var show = SlideShow()
        private var timeline = ShowTimeline(show: SlideShow())
        private var needsRedraw = true
        private var lastTime = -1.0
        private var observer: NSObjectProtocol?

        init(playback: PlaybackController) {
            self.playback = playback
            commandQueue = device?.makeCommandQueue()
            context = device.map { CIContext(mtlDevice: $0) } ?? CIContext()
            super.init()
            observer = NotificationCenter.default.addObserver(forName: ImageCache.didLoad, object: nil, queue: .main) { [weak self] _ in
                self?.needsRedraw = true
            }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }

        func update(show: SlideShow) {
            guard show != self.show else { return }
            self.show = show
            timeline = ShowTimeline(show: show)
            needsRedraw = true
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            needsRedraw = true
        }

        func draw(in view: MTKView) {
            let time = MainActor.assumeIsolated { playback.currentTime }
            guard needsRedraw || time != lastTime else { return }
            guard let drawable = view.currentDrawable,
                  let commandBuffer = commandQueue?.makeCommandBuffer() else { return }
            needsRedraw = false
            lastTime = time
            prefetch(around: time)

            // Fit the output frame inside the view.
            let drawableSize = view.drawableSize
            let aspect = show.settings.outputAspect
            var width = drawableSize.width, height = width / aspect
            if height > drawableSize.height {
                height = drawableSize.height
                width = height * aspect
            }
            let frame = FrameRenderer.render(show: show, timeline: timeline, at: time,
                                             size: CGSize(width: width.rounded(), height: height.rounded())) { slide in
                MediaStore.url(for: slide.source).flatMap { ImageCache.preview.cachedImage(for: $0) }
            }
            let bounds = CGRect(origin: .zero, size: drawableSize)
            let image = frame
                .transformed(by: CGAffineTransform(translationX: ((drawableSize.width - width) / 2).rounded(),
                                                   y: ((drawableSize.height - height) / 2).rounded()))
                .composited(over: CIImage(color: .black).cropped(to: bounds))

            let destination = CIRenderDestination(width: Int(drawableSize.width), height: Int(drawableSize.height),
                                                  pixelFormat: view.colorPixelFormat, commandBuffer: commandBuffer) {
                drawable.texture
            }
            _ = try? context.startTask(toRender: image, from: bounds, to: destination, at: .zero)
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }

        /// Loads photos visible now or within the next few seconds.
        private func prefetch(around time: Double) {
            for entry in timeline.entries where entry.end > time - 0.5 && entry.start < time + 4 {
                if let url = MediaStore.url(for: show.slides[entry.index].source) {
                    ImageCache.preview.prefetch(url)
                }
            }
        }
    }
}
