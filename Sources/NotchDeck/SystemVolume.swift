import AudioToolbox
import CoreAudio

struct AudioOutput: Identifiable, Equatable {
    let id: AudioObjectID
    let name: String
}

enum SystemVolume {
    private static func property(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func text(_ selector: AudioObjectPropertySelector, of device: AudioObjectID) -> String? {
        var address = property(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private static func hasOutputStreams(_ device: AudioObjectID) -> Bool {
        var address = property(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }

    static func outputDevices() -> [AudioOutput] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = property(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var devices = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &devices) == noErr else { return [] }
        return devices
            // 系统自动生成的聚合设备不是用户能选的输出。
            .filter { hasOutputStreams($0) && text(kAudioDevicePropertyDeviceUID, of: $0)?.hasPrefix("CADefaultDeviceAggregate") != true }
            .compactMap { device in text(kAudioObjectPropertyName, of: device).map { AudioOutput(id: device, name: $0) } }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func setOutputDevice(_ device: AudioObjectID) {
        var address = property(kAudioHardwarePropertyDefaultOutputDevice)
        var value = device
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &value)
    }

    static func outputDevice() -> AudioObjectID? {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = property(kAudioHardwarePropertyDefaultOutputDevice)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    private static var volumeAddress: AudioObjectPropertyAddress {
        property(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioDevicePropertyScopeOutput)
    }

    /// 部分输出设备（例如 HDMI 显示器）不支持软件调节音量，这时返回 nil。
    static func get() -> Float? {
        guard let device = outputDevice() else { return nil }
        var address = volumeAddress
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static var muteAddress: AudioObjectPropertyAddress {
        property(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
    }

    static func isMuted() -> Bool? {
        guard let device = outputDevice() else { return nil }
        var address = muteAddress
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }

    static func setMuted(_ muted: Bool) {
        guard let device = outputDevice() else { return }
        var address = muteAddress
        var value: UInt32 = muted ? 1 : 0
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }

    static func set(_ newValue: Float) {
        guard let device = outputDevice() else { return }
        var address = volumeAddress
        var value = Float32(min(max(newValue, 0), 1))
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
    }
}
