import AudioToolbox
import CoreAudio
import Foundation

/// Plays a short sine tone through one output device, without changing the
/// system default. Used by the "试听" button to identify physical outputs.
final class TestTonePlayer {
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var state: ToneState?
    private var started = false
    private let queue = DispatchQueue(label: "com.carlmin.soundpath.tone", qos: .userInteractive)

    deinit {
        stop()
    }

    func start(deviceUID: String, duration: Double = 0.8) throws {
        guard !started else { return }

        do {
            let aggregateUID = "SoundPath-Tone-\(UUID().uuidString)"
            let composition: [String: Any] = [
                kAudioAggregateDeviceNameKey: "SoundPath-Tone",
                kAudioAggregateDeviceUIDKey: aggregateUID,
                kAudioAggregateDeviceMainSubDeviceKey: deviceUID,
                kAudioAggregateDeviceIsPrivateKey: NSNumber(value: 1),
                kAudioAggregateDeviceIsStackedKey: NSNumber(value: 0),
                kAudioAggregateDeviceSubDeviceListKey: [
                    [kAudioSubDeviceUIDKey: deviceUID]
                ]
            ]

            var aggregate = AudioObjectID(kAudioObjectUnknown)
            try caCheck(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregate),
                        "创建试听设备失败")
            aggregateID = aggregate

            var sampleRate = 48000.0
            let streams: [AudioStreamID] = try readArrayProperty(aggregate,
                                                                 kAudioDevicePropertyStreams,
                                                                 scope: kAudioObjectPropertyScopeOutput)
            if let first = streams.first {
                let format: AudioStreamBasicDescription = try readProperty(first,
                                                                           kAudioStreamPropertyVirtualFormat,
                                                                           defaultValue: AudioStreamBasicDescription())
                guard format.mFormatID == kAudioFormatLinearPCM,
                      format.mFormatFlags & kAudioFormatFlagIsFloat != 0 else {
                    throw CoreAudioError(status: -1, operation: "试听设备不是 Float32 格式")
                }
                if format.mSampleRate > 0 { sampleRate = format.mSampleRate }
            }

            let toneState = ToneState(sampleRate: sampleRate,
                                      duration: duration,
                                      frequency: 880,
                                      amplitude: 0.12)
            state = toneState

            var procID: AudioDeviceIOProcID?
            try caCheck(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [weak self] _, _, _, output, _ in
                guard let self, let state = self.state else { return }
                Self.fillTone(output, state: state)
            }, "创建试听回调失败")
            guard let procID else {
                throw CoreAudioError(status: -1, operation: "创建试听回调失败")
            }
            ioProcID = procID

            try caCheck(AudioDeviceStart(aggregateID, procID), "播放试听音失败")
            started = true
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
                self.ioProcID = nil
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if ProcessInfo.processInfo.arguments.contains("--tone-test") {
            print("tone rendered frames=\(state?.renderedFrames ?? 0)")
        }
        state = nil
        started = false
    }

    private final class ToneState {
        let sampleRate: Double
        let totalFrames: Int
        let fadeFrames: Int
        let frequency: Double
        let amplitude: Float
        var phase: Double = 0
        var frame = 0
        var renderedFrames = 0

        init(sampleRate: Double, duration: Double, frequency: Double, amplitude: Float) {
            self.sampleRate = sampleRate
            self.totalFrames = max(1, Int(duration * sampleRate))
            self.fadeFrames = max(1, Int(0.02 * sampleRate))
            self.frequency = frequency
            self.amplitude = amplitude
        }
    }

    private static let maxChannels = 32

    private static func fillTone(_ output: UnsafeMutablePointer<AudioBufferList>, state: ToneState) {
        let buffers = UnsafeMutableAudioBufferListPointer(output)
        guard let first = buffers.first else { return }
        let framesPerBuffer = Int(first.mDataByteSize) / 4 / max(1, Int(first.mNumberChannels))
        guard framesPerBuffer > 0 else { return }

        withUnsafeTemporaryAllocation(of: UnsafeMutablePointer<Float>.self, capacity: maxChannels) { pointers in
            withUnsafeTemporaryAllocation(of: Int.self, capacity: maxChannels) { strides in
                var channelCount = 0

                for buffer in buffers {
                    guard let data = buffer.mData else { continue }
                    let channels = max(1, Int(buffer.mNumberChannels))
                    let base = data.assumingMemoryBound(to: Float.self)
                    if channels == 1 {
                        if channelCount < maxChannels {
                            pointers[channelCount] = base
                            strides[channelCount] = 1
                            channelCount += 1
                        }
                    } else {
                        for channel in 0..<channels where channelCount < maxChannels {
                            pointers[channelCount] = base + channel
                            strides[channelCount] = channels
                            channelCount += 1
                        }
                    }
                }

                guard channelCount > 0 else { return }

                for frame in 0..<framesPerBuffer {
                    let index = state.frame
                    let value: Float
                    if index >= state.totalFrames {
                        value = 0
                    } else {
                        let fadeIn = Double(index) / Double(state.fadeFrames)
                        let fadeOut = Double(state.totalFrames - index) / Double(state.fadeFrames)
                        let envelope = min(1.0, max(0.0, min(fadeIn, fadeOut)))
                        value = Float(sin(state.phase)) * state.amplitude * Float(envelope)
                        state.phase += 2 * Double.pi * state.frequency / state.sampleRate
                        if state.phase > 2 * Double.pi { state.phase -= 2 * Double.pi }
                    }

                    for channel in 0..<channelCount {
                        pointers[channel][frame * strides[channel]] = value
                    }
                    state.frame += 1
                }
                state.renderedFrames += framesPerBuffer
            }
        }
    }
}
