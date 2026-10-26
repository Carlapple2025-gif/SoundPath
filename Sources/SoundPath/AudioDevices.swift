import CoreAudio
import Foundation

struct AudioOutputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let transport: UInt32

    var isAirPlay: Bool { transport == kAudioDeviceTransportTypeAirPlay }
    var isHDMI: Bool { transport == kAudioDeviceTransportTypeHDMI }
    var isBuiltIn: Bool { transport == kAudioDeviceTransportTypeBuiltIn }

    var symbolName: String {
        if isAirPlay { return "airplayaudio" }
        if isHDMI { return "tv" }
        if name.localizedCaseInsensitiveContains("headphone")
            || name.localizedCaseInsensitiveContains("耳机")
            || name.localizedCaseInsensitiveContains("耳筒") {
            return "headphones"
        }
        return "hifispeaker"
    }

    var subtitle: String? {
        if isAirPlay { return "整机输出 · 在控制中心选目标" }
        if isHDMI { return "显示器 / HDMI" }
        if uid == "BuiltInHeadphoneOutputDevice" { return "Mac 的 3.5mm 耳机孔" }
        if transport == kAudioDeviceTransportTypeUSB { return "USB 音频" }
        return nil
    }
}

@MainActor
final class AudioDeviceCenter {
    static let managedDevicePrefix = "SoundPath-"

    private(set) var devices: [AudioOutputDevice] = []
    private(set) var defaultOutputID: AudioDeviceID = AudioDeviceID(kAudioObjectUnknown)
    private(set) var volumeControls: [AudioDeviceID: OutputVolumeControl] = [:]

    func refresh() throws {
        defaultOutputID = try systemDefaultOutputDevice()

        let ids: [AudioObjectID] = try readArrayProperty(caSystemObject, kAudioHardwarePropertyDevices)
        var found: [AudioOutputDevice] = []
        var controls: [AudioDeviceID: OutputVolumeControl] = [:]

        for id in ids where Self.hasOutputStreams(id) {
            let uid = (try? readStringProperty(id, kAudioDevicePropertyDeviceUID)) ?? ""
            guard !uid.isEmpty else { continue }
            var name = (try? readStringProperty(id, kAudioObjectPropertyName)) ?? ""
            let transport = (try? readProperty(id,
                                               kAudioDevicePropertyTransportType,
                                               defaultValue: UInt32(0))) ?? 0
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)

            // Our private aggregate is visible to this process but has no name.
            if transport == kAudioDeviceTransportTypeAggregate && trimmedName.isEmpty { continue }
            if name.hasPrefix(Self.managedDevicePrefix) { continue }

            if trimmedName.isEmpty {
                switch transport {
                case kAudioDeviceTransportTypeHDMI: name = "外接显示器"
                case kAudioDeviceTransportTypeAirPlay: name = "AirPlay"
                case kAudioDeviceTransportTypeBuiltIn: name = "内置音频"
                default: name = "音频设备 \(id)"
                }
            }
            found.append(AudioOutputDevice(id: id, uid: uid, name: name, transport: transport))
            controls[id] = OutputVolumeControl.make(for: id)
        }

        devices = found.sorted { lhs, rhs in
            if lhs.id == defaultOutputID { return true }
            if rhs.id == defaultOutputID { return false }
            if lhs.isAirPlay != rhs.isAirPlay { return !lhs.isAirPlay }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        volumeControls = controls
    }

    func setDefault(_ device: AudioOutputDevice) throws {
        try setDefaultOutputDevice(device.id)
        try refresh()
    }

    /// Aggregates created by older builds could leak into the system output list.
    /// Destroy anything we own on launch so the menu only shows real outputs.
    func removeStaleManagedDevices() {
        guard let ids: [AudioObjectID] = try? readArrayProperty(caSystemObject, kAudioHardwarePropertyDevices) else { return }
        for id in ids {
            guard let name = try? readStringProperty(id, kAudioObjectPropertyName),
                  name.hasPrefix(Self.managedDevicePrefix) else { continue }
            AudioHardwareDestroyAggregateDevice(id)
        }
    }

    private static func hasOutputStreams(_ device: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size)
        return status == noErr && size > 0
    }
}
