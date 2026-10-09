import AVFoundation

/// A music file's loudness over time, for drawing along its clips on the timeline.
struct Waveform: Sendable {
    /// Peaks per second of audio.
    static let resolution = 100.0
    /// The loudest sample (0...1) in each 1/`resolution` of a second.
    let peaks: [Float]

    /// The loudest peak between two times in the file, in seconds.
    func peak(from start: Double, to end: Double) -> Float {
        let a = max(Int(start * Self.resolution), 0)
        let b = min(Int((end * Self.resolution).rounded(.up)), peaks.count)
        guard a < b else { return 0 }
        return peaks[a..<b].max() ?? 0
    }

    /// Reads the whole file, mixed to mono at a low sample rate (plenty for a picture).
    static func read(_ url: URL) async -> Waveform? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else { return nil }
        let sampleRate = 8_000.0
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { return nil }

        let samplesPerPeak = Int(sampleRate / resolution)
        var peaks: [Float] = []
        var current: Int16 = 0
        var count = 0
        while let buffer = output.copyNextSampleBuffer() {
            if Task.isCancelled { reader.cancelReading(); return nil }
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<CChar>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
                                              dataPointerOut: &pointer) == noErr, let pointer else { continue }
            // Audio buffers from AVAssetReader are contiguous.
            pointer.withMemoryRebound(to: Int16.self, capacity: length / 2) { samples in
                for i in 0..<length / 2 {
                    let s = samples[i]
                    let magnitude = s == .min ? .max : abs(s)
                    if magnitude > current { current = magnitude }
                    count += 1
                    if count == samplesPerPeak {
                        peaks.append(Float(current) / Float(Int16.max))
                        current = 0
                        count = 0
                    }
                }
            }
        }
        if count > 0 { peaks.append(Float(current) / Float(Int16.max)) }
        return reader.status == .completed ? Waveform(peaks: peaks) : nil
    }
}

/// Waveforms read in the background, once per music file.
@MainActor
enum WaveformCache {
    private static var loaded: [URL: Waveform] = [:]
    private static var loading: [URL: Task<Waveform?, Never>] = [:]

    static func waveform(for source: MediaSource) async -> Waveform? {
        guard let url = MediaStore.url(for: source) else { return nil }
        if let waveform = loaded[url] { return waveform }
        let task = loading[url] ?? Task.detached(priority: .utility) { await Waveform.read(url) }
        loading[url] = task
        let waveform = await task.value
        loading[url] = nil
        if let waveform { loaded[url] = waveform }
        return waveform
    }
}
