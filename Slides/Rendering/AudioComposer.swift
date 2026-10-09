@preconcurrency import AVFoundation

/// Mixes the show's music clips into one composition, ending (with a fade) when the show ends.
enum AudioComposer {
    static func build(show: SlideShow, totalDuration total: Double) async -> (AVMutableComposition, AVAudioMix)? {
        guard total > 0 else { return nil }
        let composition = AVMutableComposition()
        var parameters: [AVMutableAudioMixInputParameters] = []
        let fade = max(show.settings.musicFadeOut, 0)

        for clip in show.audio {
            let start = max(clip.start, 0)
            let length = min(clip.length, clip.fileDuration - clip.offset, total - start)
            // Keep the asset alive while its track is used; a track only weakly references its asset.
            guard length > 0.01, let url = MediaStore.url(for: clip.source) else { continue }
            let asset = AVURLAsset(url: url)
            guard let sourceTrack = try? await asset.loadTracks(withMediaType: .audio).first,
                  let track = composition.addMutableTrack(withMediaType: .audio,
                                                          preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }
            do {
                try track.insertTimeRange(CMTimeRange(start: cmTime(clip.offset), duration: cmTime(length)),
                                          of: sourceTrack, at: cmTime(start))
            } catch {
                composition.removeTrack(track)
                continue
            }

            let input = AVMutableAudioMixInputParameters(track: track)
            // The mix turns the music down and fades it; a tap makes it louder.
            let volume = Float(min(clip.volume, 1))
            if clip.volume > 1.001 {
                input.audioTapProcessor = GainTap.make(gain: Float(clip.volume))
            }
            let end = start + length
            let fadeIn = clip.fadeInDuration, fadeOut = clip.fadeOutDuration
            /// The clip's own fades, times the fade at the end of the show.
            func level(_ t: Double) -> Float {
                var gain = 1.0
                if fadeIn > 0 { gain *= min(max((t - clip.start) / fadeIn, 0), 1) }
                if fadeOut > 0 { gain *= min(max((clip.end - t) / fadeOut, 0), 1) }
                if fade > 0 { gain *= min(max((total - t) / fade, 0), 1) }
                return volume * Float(gain)
            }
            // Straight-line ramps between the points where a fade starts or stops.
            let points = Set([start, clip.start + fadeIn, clip.end - fadeOut, total - fade, end]
                .filter { $0 >= start && $0 <= end }).sorted()
            input.setVolume(level(start), at: cmTime(start))
            for (a, b) in zip(points, points.dropFirst()) where b - a > 0.001 && level(a) != level(b) {
                input.setVolumeRamp(fromStartVolume: level(a), toEndVolume: level(b),
                                    timeRange: CMTimeRange(start: cmTime(a), end: cmTime(b)))
            }
            parameters.append(input)
        }

        guard !parameters.isEmpty else { return nil }
        let mix = AVMutableAudioMix()
        mix.inputParameters = parameters
        return (composition, mix)
    }

    static func cmTime(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 48_000)
    }
}
