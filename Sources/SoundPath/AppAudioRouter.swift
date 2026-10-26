import AudioToolbox
import CoreAudio
import Foundation
import os

/// Captures one app's audio with a Core Audio process tap, mutes the app's
/// original output, and forwards the samples to another output device through
/// a private aggregate device.
final class AppAudioRouter {
    let appID: String
    let appName: String
    let processObjectIDs: [AudioObjectID]
    let targetDeviceID: AudioDeviceID
    let targetDeviceName: String
    private let targetDeviceUID: String
    private let gain: RouteGain

    private let queue = DispatchQueue(label: "com.carlmin.soundpath.router", qos: .userInteractive)

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private(set) var isRunning = false
    private let stats = RouteStats()

    init(appID: String,
         appName: String,
         processObjectIDs: [AudioObjectID],
         targetDeviceID: AudioDeviceID,
         targetDeviceName: String,
         targetDeviceUID: String,
         volume: Float = 1) {
        self.appID = appID
        self.appName = appName
        self.processObjectIDs = processObjectIDs
        self.targetDeviceID = targetDeviceID
        self.targetDeviceName = targetDeviceName
        self.targetDeviceUID = targetDeviceUID
        self.gain = RouteGain(volume)
    }

    /// Software gain for this route (0…1.5). Applied in the IO callback so it
    /// works even when the target device has no writable hardware volume.
    func setVolume(_ value: Float) {
        gain.set(value)
    }

    deinit {
        stop()
    }

    func start() throws {
        guard !isRunning else { return }
        guard !processObjectIDs.isEmpty else {
            throw CoreAudioError(status: -1, operation: "这个 App 当前没有可接管的音频进程")
        }

        do {
            let description = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
            description.uuid = UUID()
            description.name = "SoundPath-\(appName)"
            description.muteBehavior = .mutedWhenTapped
            description.isPrivate = true

            var tap = AudioObjectID(kAudioObjectUnknown)
            try caCheck(AudioHardwareCreateProcessTap(description, &tap), "创建音频 Tap 失败")
            tapID = tap

            let format: AudioStreamBasicDescription = try readProperty(tapID,
                                                                       kAudioTapPropertyFormat,
                                                                       defaultValue: AudioStreamBasicDescription())
            guard format.mFormatID == kAudioFormatLinearPCM,
                  format.mFormatFlags & kAudioFormatFlagIsFloat != 0 else {
                throw CoreAudioError(status: -1, operation: "Tap 音频格式不是 Float32，暂不支持")
            }

            let aggregateUID = "SoundPath-\(UUID().uuidString)"
            let composition: [String: Any] = [
                kAudioAggregateDeviceNameKey: "SoundPath-\(appName)",
                kAudioAggregateDeviceUIDKey: aggregateUID,
                kAudioAggregateDeviceMainSubDeviceKey: targetDeviceUID,
                kAudioAggregateDeviceIsPrivateKey: NSNumber(value: 1),
                kAudioAggregateDeviceIsStackedKey: NSNumber(value: 0),
                kAudioAggregateDeviceSubDeviceListKey: [
                    [kAudioSubDeviceUIDKey: targetDeviceUID]
                ],
                kAudioAggregateDeviceTapListKey: [
                    [
                        kAudioSubTapDriftCompensationKey: NSNumber(value: 1),
                        kAudioSubTapUIDKey: description.uuid.uuidString
                    ]
                ]
            ]

            var aggregate = AudioObjectID(kAudioObjectUnknown)
            try caCheck(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregate),
                        "创建音频聚合设备失败（该输出设备可能不支持）")
            aggregateID = aggregate

            stats.enabled = ProcessInfo.processInfo.arguments.contains("--route-test")

            var procID: AudioDeviceIOProcID?
            let stats = self.stats
            let gain = self.gain
            try caCheck(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, input, _, output, _ in
                stats.callbacks += 1
                if stats.enabled { stats.inputPeak = max(stats.inputPeak, Self.peak(input)) }
                Self.copyAudio(input, output, gain: gain)
                if stats.enabled { stats.outputPeak = max(stats.outputPeak, Self.peak(output)) }
            }, "创建音频回调失败")
            guard let procID else {
                throw CoreAudioError(status: -1, operation: "创建音频回调失败")
            }
            ioProcID = procID

            try caCheck(AudioDeviceStart(aggregateID, procID), "启动音频路由失败")
            isRunning = true
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
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        isRunning = false
    }

    var debugSummary: String {
        String(format: "callbacks=%d inputPeak=%.4f outputPeak=%.4f",
               stats.callbacks, stats.inputPeak, stats.outputPeak)
    }

    // MARK: - Real-time copy (no allocation, no locks)

    private static let maxChannels = 16

    private static func peak(_ list: UnsafePointer<AudioBufferList>) -> Float {
        peak(UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list)))
    }

    private static func peak(_ list: UnsafeMutablePointer<AudioBufferList>) -> Float {
        peak(UnsafeMutableAudioBufferListPointer(list))
    }

    private static func peak(_ buffers: UnsafeMutableAudioBufferListPointer) -> Float {
        var result: Float = 0
        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            let samples = data.assumingMemoryBound(to: Float.self)
            for index in 0..<count {
                let value = abs(samples[index])
                if value > result { result = value }
            }
        }
        return result
    }

    /// Internal so `--mixer-test` can verify the gain math without audio capture.
    static func copyAudio(_ input: UnsafePointer<AudioBufferList>,
                          _ output: UnsafeMutablePointer<AudioBufferList>,
                          gain: RouteGain) {
        // One ramp per IO block: no zipper noise when the slider moves,
        // no allocation and no blocking inside the callback.
        let ramp = gain.step()
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let destination = UnsafeMutableAudioBufferListPointer(output)
        guard let firstSource = source.first, let firstDestination = destination.first else { return }

        let isUnity = abs(ramp.from - 1) < 0.0001 && abs(ramp.to - 1) < 0.0001

        // Common case: unity gain and both sides share an interleaved Float32 layout.
        if isUnity,
           source.count == 1,
           destination.count == 1,
           firstSource.mNumberChannels == firstDestination.mNumberChannels,
           firstSource.mDataByteSize == firstDestination.mDataByteSize,
           let sourceData = firstSource.mData,
           let destinationData = firstDestination.mData {
            memcpy(destinationData, sourceData, Int(firstDestination.mDataByteSize))
            return
        }

        let sourceFrames = Int(firstSource.mDataByteSize) / 4 / max(1, Int(firstSource.mNumberChannels))

        withUnsafeTemporaryAllocation(of: UnsafePointer<Float>.self, capacity: maxChannels) { sourcePointers in
            withUnsafeTemporaryAllocation(of: Int.self, capacity: maxChannels) { sourceStrides in
                var sourceChannelCount = 0

                for buffer in source {
                    guard let data = buffer.mData else { continue }
                    let channels = max(1, Int(buffer.mNumberChannels))
                    let base = UnsafePointer(data.assumingMemoryBound(to: Float.self))
                    if channels == 1 {
                        if sourceChannelCount < maxChannels {
                            sourcePointers[sourceChannelCount] = base
                            sourceStrides[sourceChannelCount] = 1
                            sourceChannelCount += 1
                        }
                    } else {
                        for channel in 0..<channels where sourceChannelCount < maxChannels {
                            sourcePointers[sourceChannelCount] = base + channel
                            sourceStrides[sourceChannelCount] = channels
                            sourceChannelCount += 1
                        }
                    }
                }

                guard sourceChannelCount > 0 else { return }

                withUnsafeTemporaryAllocation(of: UnsafeMutablePointer<Float>.self, capacity: maxChannels) { destinationPointers in
                    withUnsafeTemporaryAllocation(of: Int.self, capacity: maxChannels) { destinationStrides in
                        var destinationChannelCount = 0
                        var frames = sourceFrames

                        for buffer in destination {
                            guard let data = buffer.mData else { continue }
                            let channels = max(1, Int(buffer.mNumberChannels))
                            frames = min(frames, Int(buffer.mDataByteSize) / 4 / channels)
                            let base = data.assumingMemoryBound(to: Float.self)
                            for channel in 0..<channels where destinationChannelCount < maxChannels {
                                destinationPointers[destinationChannelCount] = base + channel
                                destinationStrides[destinationChannelCount] = channels
                                destinationChannelCount += 1
                            }
                        }

                        guard destinationChannelCount > 0, frames > 0 else { return }

                        let step = (ramp.to - ramp.from) / Float(frames)
                        let needsClip = ramp.from > 1 || ramp.to > 1
                        for frame in 0..<frames {
                            let blockGain = ramp.from + step * Float(frame + 1)
                            for channel in 0..<destinationChannelCount {
                                let sourceIndex = min(channel, sourceChannelCount - 1)
                                var sample = sourcePointers[sourceIndex][frame * sourceStrides[sourceIndex]] * blockGain
                                if needsClip { sample = min(1, max(-1, sample)) }
                                destinationPointers[channel][frame * destinationStrides[channel]] = sample
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Lock-free (for readers) software gain for a route. The IO callback uses
/// `step()` which never blocks: if the UI happens to be writing, the previous
/// target is reused and the ramp simply catches up on the next block.
final class RouteGain {
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private var target: Float
    /// Only touched by the IO thread.
    private var applied: Float

    init(_ value: Float) {
        lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
        target = value
        applied = value
    }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    var value: Float {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return target
    }

    func set(_ newValue: Float) {
        let clamped = min(1.5, max(0, newValue))
        os_unfair_lock_lock(lock)
        target = clamped
        os_unfair_lock_unlock(lock)
    }

    /// IO thread only. Returns the gain to ramp from/to for this block.
    func step() -> (from: Float, to: Float) {
        let from = applied
        if os_unfair_lock_trylock(lock) {
            applied = target
            os_unfair_lock_unlock(lock)
        }
        return (from, applied)
    }
}



final class RouteStats {
    var enabled = false
    var callbacks = 0
    var inputPeak: Float = 0
    var outputPeak: Float = 0
}
