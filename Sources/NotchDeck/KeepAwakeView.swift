import SwiftUI

/// 防止休眠的开关和时长选择，首页底部和快捷开关页都用这个弹出面板。
struct KeepAwakePanel: View {
    @ObservedObject private var controls = QuickControls.shared
    private static let minuteOptions = [15, 30, 45]
    private static let hourOptions = [1, 4, 8, 12]

    private func chip(_ label: String, minutes: Int?) -> some View {
        let selected = controls.keepAwake && controls.keepAwakeDuration == minutes
        return Button { controls.startKeepAwake(minutes: minutes) } label: {
            Text(label)
                .font(.system(size: minutes == nil ? 16 : 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(selected ? Color.white : Theme.primary)
                .frame(width: 32, height: 32)
                .background(Circle().fill(selected ? Theme.blue : Theme.control))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(minutes.map { formatDuration(minutes: $0) } ?? L("一直"))
    }

    private var dot: some View {
        Circle().fill(Theme.tertiary).frame(width: 4, height: 4).frame(height: 32)
    }

    private func group(_ caption: String, _ chips: some View) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) { chips }
            Text(caption).font(.system(size: 10)).foregroundStyle(Theme.tertiary)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L("防止休眠")).font(.system(size: 14, weight: .semibold))
                Spacer()
                Toggle("", isOn: Binding(
                    get: { controls.keepAwake },
                    set: { $0 ? controls.startKeepAwake(minutes: nil) : controls.stopKeepAwake() }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }
            Divider()
            HStack {
                Text(L("持续时间")).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
                Spacer()
                if let left = controls.keepAwakeMinutesLeft {
                    Text(L("剩余 %@", formatDuration(minutes: left)))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.teal)
                        .monospacedDigit()
                }
            }
            HStack(alignment: .top, spacing: 8) {
                group(L("一直"), chip("∞", minutes: nil))
                dot
                group(L("分钟"), ForEach(Self.minuteOptions, id: \.self) { chip("\($0)", minutes: $0) })
                dot
                group(L("小时"), ForEach(Self.hourOptions, id: \.self) { chip(String(format: "%02d", $0), minutes: $0 * 60) })
            }
        }
        .padding(14)
        .fixedSize()
    }
}

/// 首页底部的入口：显示当前状态，点击弹出 KeepAwakePanel。
struct KeepAwakeButton: View {
    @ObservedObject private var controls = QuickControls.shared
    @State private var showing = false

    private var label: String {
        guard controls.keepAwake else { return L("防止休眠") }
        return controls.keepAwakeMinutesLeft.map { formatCompactDuration(minutes: $0) } ?? L("已开启")
    }

    var body: some View {
        Button { showing.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: controls.keepAwake ? "cup.and.saucer.fill" : "cup.and.saucer")
                    .foregroundStyle(controls.keepAwake ? Theme.blue : Theme.orange)
                Text(label).font(.system(size: 13, weight: .medium)).monospacedDigit().lineLimit(1).fixedSize()
            }
            .padding(.horizontal, 14)
            .frame(height: 36)
            .capsuleFill(Theme.control)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showing, arrowEdge: .bottom) { KeepAwakePanel() }
        .help(L("防止休眠"))
    }
}
