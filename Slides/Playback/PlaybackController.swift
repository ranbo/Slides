@preconcurrency import AVFoundation
import Observation
import QuartzCore

/// The preview's clock, with the music kept in step.
@MainActor @Observable
final class PlaybackController {
    /// The playhead position. Updated about 30 times a second while playing; use
    /// `currentTime` when you need the exact value for a frame.
    private(set) var time: Double = 0
    private(set) var isPlaying = false
    var duration: Double = 0 {
        didSet { if time > duration { time = max(duration, 0) } }
    }

    @ObservationIgnored private var anchorTime: Double = 0
    @ObservationIgnored private var anchorHostTime: CFTimeInterval = 0
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var hasAudio = false
    @ObservationIgnored private let player: AVPlayer = {
        let player = AVPlayer()
        player.automaticallyWaitsToMinimizeStalling = false
        return player
    }()

    var currentTime: Double {
        guard isPlaying else { return time }
        return min(max(anchorTime + CACurrentMediaTime() - anchorHostTime, 0), duration)
    }

    func togglePlay() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard !isPlaying, duration > 0 else { return }
        if time >= duration - 0.01 { time = 0 }
        isPlaying = true
        start(from: time)
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func pause() {
        if isPlaying { time = currentTime }
        isPlaying = false
        timer?.invalidate()
        timer = nil
        player.pause()
    }

    func seek(to seconds: Double) {
        let t = min(max(seconds, 0), duration)
        time = t
        if isPlaying {
            start(from: t)
        } else if hasAudio {
            player.seek(to: AudioComposer.cmTime(t), toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    /// Replaces the music. Pass nil when the show has none.
    func setAudio(_ audio: (AVMutableComposition, AVAudioMix)?) {
        let wasPlaying = isPlaying
        if wasPlaying { pause() }
        if let (composition, mix) = audio {
            let item = AVPlayerItem(asset: composition)
            item.audioMix = mix
            player.replaceCurrentItem(with: item)
            hasAudio = true
        } else {
            player.replaceCurrentItem(with: nil)
            hasAudio = false
        }
        if wasPlaying { play() } else { seek(to: time) }
    }

    /// Starts the clock and the music together, a moment from now.
    private func start(from t: Double) {
        let hostTime = CACurrentMediaTime() + 0.05
        anchorTime = t
        anchorHostTime = hostTime
        if hasAudio {
            player.setRate(1, time: AudioComposer.cmTime(t),
                           atHostTime: CMTime(seconds: hostTime, preferredTimescale: 1_000_000_000))
        }
    }

    private func tick() {
        let t = currentTime
        if t >= duration {
            pause()
            time = duration
        } else {
            time = t
        }
    }
}
