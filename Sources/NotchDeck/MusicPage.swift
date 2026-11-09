import AppKit
import AudioToolbox
import CoreAudio
import SwiftUI

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

struct MusicPage: View {
    @ObservedObject var model: PanelModel
    @ObservedObject private var media = MediaController.shared
    @State private var scrubbing: Double?
    @State private var volume: Float?

    private let volumeTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var hasMedia: Bool { !media.title.isEmpty }

    private func time(_ value: Double) -> String {
        let total = Int(max(value, 0))
        if total >= 3600 { return String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60) }
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private var artwork: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.control)
            if let image = media.artwork {
                Image(nsImage: image).resizable().scaledToFill()
            } else if let icon = media.sourceIcon {
                Image(nsImage: icon).resizable().frame(width: 72, height: 72)
            } else {
                Image(systemName: "music.note").font(.system(size: 38)).foregroundStyle(Theme.tertiary)
            }
        }
        .frame(width: 136, height: 136)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var subtitle: String {
        [media.artist, media.album].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var progress: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let position = scrubbing ?? media.position(at: timeline.date)
            HStack(spacing: 8) {
                Text(time(position)).frame(width: 52, alignment: .trailing)
                Slider(
                    value: Binding(get: { min(position, max(media.duration, 1)) }, set: { scrubbing = $0 }),
                    in: 0...max(media.duration, 1),
                    onEditingChanged: { editing in
                        if !editing, let target = scrubbing {
                            media.seek(to: target)
                            scrubbing = nil
                        }
                    }
                )
                .controlSize(.small)
                .disabled(media.duration <= 0)
                Text(time(media.duration)).frame(width: 52, alignment: .leading)
            }
            .font(.system(size: 11))
            .monospacedDigit()
            .foregroundStyle(Theme.secondary)
        }
    }

    private func control(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 18)).frame(width: 40, height: 40).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var playButton: some View {
        Button { media.togglePlayPause() } label: {
            Image(systemName: media.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 18))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Theme.coral))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var volumeControl: some View {
        if let volume {
            HStack(spacing: 6) {
                Image(systemName: volume <= 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
                    .frame(width: 18)
                Slider(
                    value: Binding(
                        get: { Double(volume) },
                        set: { newValue in
                            self.volume = Float(newValue)
                            SystemVolume.set(Float(newValue))
                        }
                    ),
                    in: 0...1
                )
                .controlSize(.small)
                .frame(width: 120)
            }
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            PageHeader(title: L("音乐"), model: model) {
                if !media.sourceName.isEmpty {
                    Text(L("来自 %@", media.sourceName)).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
            }
            Card(padding: 10) {
                HStack(spacing: 16) {
                    artwork
                    VStack(alignment: .leading, spacing: 4) {
                        Text(hasMedia ? media.title : L("未在播放"))
                            .font(.system(size: 18, weight: .semibold))
                            .lineLimit(1)
                        Text(subtitle.isEmpty ? " " : subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        progress
                        ZStack {
                            HStack(spacing: 10) {
                                control("backward.fill") { media.previous() }
                                playButton
                                control("forward.fill") { media.next() }
                            }
                            .opacity(hasMedia ? 1 : 0.45)
                            .disabled(!hasMedia)
                            HStack {
                                Spacer()
                                volumeControl
                            }
                        }
                    }
                }
            }
        }
        .onAppear { volume = SystemVolume.get() }
        .onReceive(volumeTimer) { _ in volume = SystemVolume.get() }
    }
}
