import AppKit
import SwiftUI

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

struct MusicCard: View {
    @ObservedObject private var media = MediaController.shared

    private var hasMedia: Bool { !media.title.isEmpty }

    private func control(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15)).frame(width: 28, height: 34).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Image(systemName: "music.note").foregroundStyle(Theme.coral)
                    Text(hasMedia ? media.title : L("未在播放"))
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                }
                Text(media.artist.isEmpty ? " " : media.artist)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                HStack(spacing: 0) {
                    control("backward.fill") { media.previous() }
                    Spacer(minLength: 0)
                    Button { media.togglePlayPause() } label: {
                        Image(systemName: media.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(Theme.coral))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    Spacer(minLength: 0)
                    control("forward.fill") { media.next() }
                }
                .opacity(hasMedia ? 1 : 0.45)
                .disabled(!hasMedia)
            }
        }
    }
}
