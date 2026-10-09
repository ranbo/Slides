@preconcurrency import AVFoundation
import CoreImage
import os

/// Renders the show and its music to an H.264 .mp4 file.
final class VideoExporter: @unchecked Sendable {
    enum Failure: LocalizedError {
        case nothingToExport
        case cancelled
        case writer(String)

        var errorDescription: String? {
            switch self {
            case .nothingToExport: "There are no photos to export."
            case .cancelled: "The export was cancelled."
            case .writer(let message): message
            }
        }
    }

    /// Called on a background queue with values from 0 to 1.
    var onProgress: (@Sendable (Double) -> Void)?

    private let show: SlideShow
    private let timeline: ShowTimeline
    private let outputURL: URL
    private let cancelled = OSAllocatedUnfairLock(initialState: false)

    init(show: SlideShow, outputURL: URL) {
        self.show = show
        self.timeline = ShowTimeline(show: show)
        self.outputURL = outputURL
    }

    func cancel() {
        cancelled.withLock { $0 = true }
    }

    private var isCancelled: Bool { cancelled.withLock { $0 } }

    /// Black, silent seconds after the show, so the fade to black finishes before the movie ends.
    static let blackTail = 0.5

    /// Tracks one writer input's progress across its callbacks.
    private final class InputState: @unchecked Sendable {
        var frame = 0
        var finished = false
        /// Where the audio written so far ends, and its format.
        var end = CMTime.zero
        var format: CMFormatDescription?
    }

    func run() async throws {
        let settings = show.settings
        let total = timeline.duration
        guard total > 0 else { throw Failure.nothingToExport }
        // Frames past the show's end render black.
        let movieLength = total + Self.blackTail
        let fps = settings.frameRate
        let frameCount = Int((movieLength * Double(fps)).rounded(.up))
        let size = CGSize(width: settings.outputWidth, height: settings.outputHeight)

        try? FileManager.default.removeItem(at: outputURL)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: settings.outputWidth,
            AVVideoHeightKey: settings.outputHeight,
            AVVideoCompressionPropertiesKey: [
                // Slow zooms over detailed photos need a generous bit rate to avoid shimmering.
                AVVideoAverageBitRateKey: 20_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps * 2,
            ],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ])
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: settings.outputWidth,
            kCVPixelBufferHeightKey as String: settings.outputHeight,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        writer.add(videoInput)

        var reader: AVAssetReader?
        var audioOutput: AVAssetReaderAudioMixOutput?
        var audioInput: AVAssetWriterInput?
        if let (composition, mix) = await AudioComposer.build(show: show, totalDuration: total) {
            let assetReader = try AVAssetReader(asset: composition)
            let output = AVAssetReaderAudioMixOutput(audioTracks: composition.tracks(withMediaType: .audio), audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            output.audioMix = mix
            assetReader.timeRange = CMTimeRange(start: .zero, duration: AudioComposer.cmTime(total))
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 256_000,
            ])
            input.expectsMediaDataInRealTime = false
            if assetReader.canAdd(output), writer.canAdd(input) {
                assetReader.add(output)
                writer.add(input)
                reader = assetReader
                audioOutput = output
                audioInput = input
            }
        }

        guard writer.startWriting() else {
            throw Failure.writer(writer.error?.localizedDescription ?? "Couldn't start writing the movie.")
        }
        writer.startSession(atSourceTime: .zero)
        if let reader, !reader.startReading() {
            writer.cancelWriting()
            throw Failure.writer(reader.error?.localizedDescription ?? "Couldn't read the music.")
        }

        let context = CIContext(options: [.cacheIntermediates: false])
        let colorSpace = CGColorSpace(name: CGColorSpace.itur_709) ?? CGColorSpaceCreateDeviceRGB()
        let images = ImageCache(maxPixelSize: 4096, capacity: 4)
        let show = self.show, timeline = self.timeline

        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let group = DispatchGroup()

            group.enter()
            let video = InputState()
            videoInput.requestMediaDataWhenReady(on: DispatchQueue(label: "Slides.export.video")) { [self] in
                guard !video.finished else { return }
                while videoInput.isReadyForMoreMediaData {
                    var appended = false
                    if !isCancelled, video.frame < frameCount, writer.status == .writing {
                        autoreleasepool {
                            guard let pool = adaptor.pixelBufferPool else { return }
                            var buffer: CVPixelBuffer?
                            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
                            guard let buffer else { return }
                            let time = Double(video.frame) / Double(fps)
                            let frame = FrameRenderer.render(show: show, timeline: timeline, at: time, size: size) { slide in
                                MediaStore.url(for: slide.source).flatMap { images.image(for: $0) }
                            }
                            context.render(frame, to: buffer, bounds: CGRect(origin: .zero, size: size), colorSpace: colorSpace)
                            appended = adaptor.append(buffer, withPresentationTime:
                                CMTime(value: CMTimeValue(video.frame), timescale: CMTimeScale(fps)))
                        }
                    }
                    guard appended else {
                        videoInput.markAsFinished()
                        video.finished = true
                        group.leave()
                        return
                    }
                    video.frame += 1
                    onProgress?(Double(video.frame) / Double(frameCount))
                }
            }

            if let audioInput, let audioOutput {
                group.enter()
                let audio = InputState()
                audioInput.requestMediaDataWhenReady(on: DispatchQueue(label: "Slides.export.audio")) { [self] in
                    guard !audio.finished else { return }
                    let movieEnd = AudioComposer.cmTime(movieLength)
                    while audioInput.isReadyForMoreMediaData {
                        if !isCancelled, let sample = audioOutput.copyNextSampleBuffer() ?? Self.silence(after: audio, until: movieEnd),
                           audioInput.append(sample) {
                            audio.end = CMSampleBufferGetPresentationTimeStamp(sample) + CMSampleBufferGetDuration(sample)
                            audio.format = CMSampleBufferGetFormatDescription(sample)
                            continue
                        }
                        audioInput.markAsFinished()
                        audio.finished = true
                        group.leave()
                        return
                    }
                }
            }

            group.notify(queue: .global()) { done.resume() }
        }

        if isCancelled {
            writer.cancelWriting()
            reader?.cancelReading()
            try? FileManager.default.removeItem(at: outputURL)
            throw Failure.cancelled
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw Failure.writer(writer.error?.localizedDescription ?? "The movie couldn't be written.")
        }
    }

    /// Up to a tenth of a second of silence following the music, until the movie ends; nil once it does.
    private static func silence(after audio: InputState, until end: CMTime) -> CMSampleBuffer? {
        guard let format = audio.format, audio.end < end,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              asbd.mBytesPerFrame > 0, asbd.mSampleRate > 0
        else { return nil }
        let remaining = Int(((end - audio.end).seconds * asbd.mSampleRate).rounded(.up))
        let frames = min(remaining, Int(asbd.mSampleRate / 10))
        guard frames > 0 else { return nil }
        let bytes = frames * Int(asbd.mBytesPerFrame)
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: bytes,
                                                 flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
              let block, CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0,
                                                    dataLength: bytes) == noErr
        else { return nil }
        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: frames,
            presentationTimeStamp: audio.end, packetDescriptions: nil, sampleBufferOut: &sample)
        return sample
    }
}
