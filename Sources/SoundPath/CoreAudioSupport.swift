import AudioToolbox
import CoreAudio
import Foundation

/// Wraps an OSStatus returned by a Core Audio call.
struct CoreAudioError: LocalizedError {
    let status: OSStatus
    let operation: String

    var errorDescription: String? {
        "\(operation)（错误码 \(status) / \(status.fourCC)）"
    }
}

extension OSStatus {
    var fourCC: String {
        let value = UInt32(bitPattern: self)
        let bytes = [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ]
        let scalars = bytes.map { byte -> Character in
            let printable = (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
            return printable ? Character(UnicodeScalar(byte)) : "."
        }
        return String(scalars)
    }
}

func caCheck(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else { throw CoreAudioError(status: status, operation: operation) }
}

let caSystemObject = AudioObjectID(kAudioObjectSystemObject)

func readProperty<T>(_ objectID: AudioObjectID,
                     _ selector: AudioObjectPropertySelector,
                     scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                     element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
                     defaultValue: T) throws -> T {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    var size: UInt32 = 0
    try caCheck(AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size), "读取属性大小失败")

    var value = defaultValue
    var status: OSStatus = noErr
    withUnsafeMutablePointer(to: &value) { pointer in
        status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, pointer)
    }
    try caCheck(status, "读取属性失败")
    return value
}

func readStringProperty(_ objectID: AudioObjectID,
                        _ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) throws -> String {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    var size: UInt32 = 0
    try caCheck(AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size), "读取字符串属性大小失败")

    var value: Unmanaged<CFString>?
    var status: OSStatus = noErr
    withUnsafeMutablePointer(to: &value) { pointer in
        status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, pointer)
    }
    try caCheck(status, "读取字符串属性失败")
    return value?.takeRetainedValue() as String? ?? ""
}

func readArrayProperty<T: FixedWidthInteger>(_ objectID: AudioObjectID,
                                             _ selector: AudioObjectPropertySelector,
                                             scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> [T] {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    try caCheck(AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size), "读取数组属性大小失败")
    guard size > 0 else { return [] }

    let count = Int(size) / MemoryLayout<T>.size
    var values = [T](repeating: 0, count: count)
    var status: OSStatus = noErr
    values.withUnsafeMutableBufferPointer { buffer in
        status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, buffer.baseAddress!)
    }
    try caCheck(status, "读取数组属性失败")
    return values
}

func setProperty<T>(_ objectID: AudioObjectID,
                    _ selector: AudioObjectPropertySelector,
                    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                    element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
                    value: T) throws {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    var mutableValue = value
    try withUnsafeBytes(of: &mutableValue) { buffer in
        try caCheck(AudioObjectSetPropertyData(objectID,
                                               &address,
                                               0,
                                               nil,
                                               UInt32(buffer.count),
                                               buffer.baseAddress!),
                    "写入属性失败")
    }
}

// MARK: - Per-device output volume

/// Hardware volume of one output device. Control Center only offers a slider
/// for the *default* output; this lets 声路 adjust every other output too.
///
/// Most devices expose a single "main" volume element; a few only expose
/// per-channel elements, so both are handled. Devices without a writable
/// volume (many HDMI displays) report `isSupported == false` and the UI falls
/// back to the per-route software gain.
struct OutputVolumeControl {
    let deviceID: AudioDeviceID
    let elements: [AudioObjectPropertyElement]

    var isSupported: Bool { !elements.isEmpty }

    static func make(for deviceID: AudioDeviceID) -> OutputVolumeControl {
        if isOutputVolumeSettable(deviceID, element: kAudioObjectPropertyElementMain) {
            return OutputVolumeControl(deviceID: deviceID, elements: [kAudioObjectPropertyElementMain])
        }
        var elements: [AudioObjectPropertyElement] = []
        for channel in 1...2 where isOutputVolumeSettable(deviceID, element: AudioObjectPropertyElement(channel)) {
            elements.append(AudioObjectPropertyElement(channel))
        }
        return OutputVolumeControl(deviceID: deviceID, elements: elements)
    }

    func read() -> Float? {
        guard let element = elements.first else { return nil }
        return readOutputVolumeScalar(deviceID, element: element)
    }

    func write(_ value: Float) throws {
        for element in elements {
            try writeOutputVolumeScalar(deviceID, value: value, element: element)
        }
    }
}

private func outputVolumeAddress(_ element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                               mScope: kAudioObjectPropertyScopeOutput,
                               mElement: element)
}

func isOutputVolumeSettable(_ deviceID: AudioObjectID, element: AudioObjectPropertyElement) -> Bool {
    var address = outputVolumeAddress(element)
    guard AudioObjectHasProperty(deviceID, &address) else { return false }
    var settable: DarwinBoolean = false
    guard AudioObjectIsPropertySettable(deviceID, &address, &settable) == noErr else { return false }
    return settable.boolValue
}

func readOutputVolumeScalar(_ deviceID: AudioObjectID, element: AudioObjectPropertyElement) -> Float? {
    var address = outputVolumeAddress(element)
    var size = UInt32(MemoryLayout<Float32>.size)
    var value: Float32 = 0
    guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else { return nil }
    return value
}

func writeOutputVolumeScalar(_ deviceID: AudioObjectID,
                             value: Float,
                             element: AudioObjectPropertyElement) throws {
    var address = outputVolumeAddress(element)
    var scalar = Float32(min(1, max(0, value)))
    try caCheck(AudioObjectSetPropertyData(deviceID,
                                           &address,
                                           0,
                                           nil,
                                           UInt32(MemoryLayout<Float32>.size),
                                           &scalar),
                "设置输出音量失败")
}

func setDefaultOutputDevice(_ deviceID: AudioDeviceID) throws {
    try setProperty(caSystemObject,
                    kAudioHardwarePropertyDefaultOutputDevice,
                    value: deviceID)

    // Keep alert/system sounds on the same device. Some Macs allow these two
    // to diverge; radio/all output is confusing when that happens.
    try? setProperty(caSystemObject,
                     kAudioHardwarePropertyDefaultSystemOutputDevice,
                     value: deviceID)
}

func systemDefaultOutputDevice() throws -> AudioDeviceID {
    try readProperty(caSystemObject,
                     kAudioHardwarePropertyDefaultOutputDevice,
                     defaultValue: AudioDeviceID(kAudioObjectUnknown))
}
