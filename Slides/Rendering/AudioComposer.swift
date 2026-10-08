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

            let volume = Float(clip.volume)
            let input = AVMutableAudioMixInputParameters(track: track)
            input.setVolume(volume, at: .zero)
            let end = start + length
            if fade > 0, end > total - fade {
                let fadeStart = max(start, total - fade)
                func level(_ t: Double) -> Float { volume * Float(min(max((total - t) / fade, 0), 1)) }
                input.setVolumeRamp(fromStartVolume: level(fadeStart), toEndVolume: level(end),
                                    timeRange: CMTimeRange(start: cmTime(fadeStart), end: cmTime(end)))
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
