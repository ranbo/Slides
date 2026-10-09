import SwiftUI

/// Gain and fades for a music clip, with the whole song's waveform showing the part used.
struct AudioClipEditorView: View {
    let clip: AudioClip
    /// How many clips the controls change (the selection, if it includes this clip).
    let editCount: Int
    /// Applies a change to every clip being edited, as one undo step.
    var apply: ((inout AudioClip) -> Void) -> Void
    /// Plays the show from a time.
    var onPlay: (Double) -> Void

    @State private var waveform: Waveform?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Label(clip.name, systemImage: "music.note").font(.title3.bold())
                Text("Plays \(formatTime(clip.offset))–\(formatTime(clip.offset + clip.length)) of the song (\(formatTime(clip.fileDuration))), starting \(formatTime(clip.start)) into the show.")
                    .foregroundStyle(.secondary)
                SongView(clip: clip, waveform: waveform)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            if editCount > 1 {
                Label("Changes below apply to all \(editCount) selected music clips.", systemImage: "square.stack.3d.up")
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
        .task(id: clip.source) { waveform = await WaveformCache.waveform(for: clip.source) }
    }

    private var controls: some View {
        HStack(alignment: .top, spacing: 28) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("Gain")
                    CommitSlider(value: clip.gainDB, range: AudioClip.gainRange) { db in apply { $0.gainDB = db } }
                        .frame(width: 200)
                    Text(String(format: "%+.1f dB", clip.gainDB))
                        .monospacedDigit()
                        .frame(width: 64, alignment: .trailing)
                    Button("Reset") { apply { $0.volume = 1 } }
                        .controlSize(.small)
                        .disabled(abs(clip.gainDB) < 0.05)
                }
                fadeRow("Fade in", value: clip.fadeIn, used: clip.fadeInDuration, automatic: clip.isTrimmedAtStart) { c, v in
                    c.fadeIn = v
                }
                fadeRow("Fade out", value: clip.fadeOut, used: clip.fadeOutDuration, automatic: clip.isTrimmedAtEnd) { c, v in
                    c.fadeOut = v
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Button("Play Start", systemImage: "play.fill") { onPlay(clip.start) }
                    .help("Play the show from the start of this clip")
                Button("Play End", systemImage: "play.fill") { onPlay(max(clip.end - 4, clip.start)) }
                    .help("Play the last few seconds of this clip, to hear how it ends")
            }
            Spacer(minLength: 0)
        }
    }

    private func fadeRow(_ title: String, value: Double?, used: Double, automatic trimmed: Bool,
                         set: @escaping (inout AudioClip, Double?) -> Void) -> some View {
        GridRow {
            Text(title)
            CommitSlider(value: used, range: 0...min(10, max(clip.length / 2, 0.1))) { v in
                apply { set(&$0, (v * 10).rounded() / 10) }
            }
            .frame(width: 200)
            Text(String(format: "%.1f s", used))
                .monospacedDigit()
                .frame(width: 64, alignment: .trailing)
            if value == nil {
                Text(trimmed ? "Automatic: trimmed end" : "Automatic: none at an untrimmed end")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button("Automatic") { apply { set(&$0, nil) } }
                    .controlSize(.small)
                    .help("Fade \(AudioClip.automaticFade.formatted()) s if this end is trimmed, otherwise not at all")
            }
        }
    }
}

/// The whole song's waveform. The part the clip plays is bright, with its fades drawn over it.
private struct SongView: View {
    let clip: AudioClip
    let waveform: Waveform?

    var body: some View {
        Canvas { context, size in
            let duration = max(clip.fileDuration, 0.01)
            func x(_ t: Double) -> CGFloat { t / duration * size.width }
            let used = CGRect(x: x(clip.offset), y: 0, width: x(clip.offset + clip.length) - x(clip.offset),
                              height: size.height)
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.secondary.opacity(0.08)))
            context.fill(Path(used), with: .color(.green.opacity(0.25)))

            if let waveform {
                let scale = Float(size.height - 4)
                var inside = Path(), outside = Path()
                var px = 0.0
                while px < size.width {
                    let t = px / size.width * duration
                    let h = max(CGFloat(waveform.peak(from: t, to: t + 2 / size.width * duration) * scale), 1)
                    let bar = CGRect(x: px, y: (size.height - h) / 2, width: 1.5, height: h)
                    if bar.midX >= used.minX && bar.midX <= used.maxX { inside.addRect(bar) } else { outside.addRect(bar) }
                    px += 2
                }
                context.fill(outside, with: .color(.secondary.opacity(0.35)))
                context.fill(inside, with: .color(.green))
            }

            // The volume envelope: up through the fade in, across, down through the fade out.
            var envelope = Path()
            envelope.move(to: CGPoint(x: used.minX, y: size.height))
            envelope.addLine(to: CGPoint(x: x(clip.offset + clip.fadeInDuration), y: 2))
            envelope.addLine(to: CGPoint(x: x(clip.offset + clip.length - clip.fadeOutDuration), y: 2))
            envelope.addLine(to: CGPoint(x: used.maxX, y: size.height))
            context.stroke(envelope, with: .color(.yellow), lineWidth: 2)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(.separator) }
    }
}
