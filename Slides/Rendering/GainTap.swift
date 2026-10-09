import Accelerate
import AVFoundation
import MediaToolbox

/// Makes a track louder. An audio mix's volume can only turn a track down (it stops at 1),
/// so a boost is applied to the samples themselves, in the preview and the export alike.
enum GainTap {
    private final class State {
        var gain: Float
        var isFloat = false
        init(gain: Float) { self.gain = gain }
    }

    static func make(gain: Float) -> MTAudioProcessingTap? {
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passRetained(State(gain: gain)).toOpaque(),
            init: { _, clientInfo, storage in storage.pointee = clientInfo },
            finalize: { tap in
                Unmanaged<State>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { tap, _, format in
                let state = Unmanaged<State>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                let description = format.pointee
                state.isFloat = description.mFormatID == kAudioFormatLinearPCM
                    && description.mFormatFlags & kAudioFormatFlagIsFloat != 0
                    && description.mBitsPerChannel == 32
            },
            unprepare: nil,
            process: { tap, frames, _, buffers, framesOut, flagsOut in
                guard MTAudioProcessingTapGetSourceAudio(tap, frames, buffers, flagsOut, nil, framesOut) == noErr
                else { return }
                let state = Unmanaged<State>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                guard state.isFloat else { return }
                var gain = state.gain
                for buffer in UnsafeMutableAudioBufferListPointer(buffers) {
                    guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                    let count = vDSP_Length(Int(buffer.mDataByteSize) / MemoryLayout<Float>.size)
                    vDSP_vsmul(data, 1, &gain, data, 1, count)
                }
            })
        var tap: MTAudioProcessingTap?
        guard MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                                         kMTAudioProcessingTapCreationFlag_PostEffects, &tap) == noErr
        else { return nil }
        return tap
    }
}
