import IOKit.pwr_mgt
import SwiftUI

/// 向系统申请“屏幕不要因闲置而休眠”，释放后恢复。防止休眠和装忙都用它。
/// 名字会显示在 pmset 等系统工具里，要用英文：中文名在那里会显示成空白。
final class DisplayWakeLock {
    private let name: String
    private var assertion: IOPMAssertionID = 0
    private(set) var isHeld = false

    init(name: String) { self.name = name }

    deinit { release() }

    @discardableResult
    func acquire() -> Bool {
        guard !isHeld else { return true }
        let status = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            name as CFString,
            &assertion
        )
        isHeld = status == kIOReturnSuccess
        return isHeld
    }

    func release() {
        guard isHeld else { return }
        IOPMAssertionRelease(assertion)
        isHeld = false
    }
}

/// 防止休眠：可以一直开着，也可以定时，到时间自动关闭。
final class KeepAwake: ObservableObject {
    static let shared = KeepAwake()
    static let durations = [15, 30, 45, 60, 240, 480, 720]
    /// 自动更新重启时记下的状态，新版本启动时恢复，用完就删。
    private static let restartKey = "keepAwakeAfterRestart"

    @Published private(set) var isOn = false
    /// 定时的时长（分钟），一直开着时为 nil。
    @Published private(set) var duration: Int?
    /// 剩余分钟数，向上取整；一直开着或已关闭时为 nil。
    @Published private(set) var minutesLeft: Int?

    private let lock = DisplayWakeLock(name: "NotchDeck Keep Awake")
    private var end: Date?
    private var timer: Timer?

    func toggle() {
        isOn ? stop() : start(minutes: nil)
    }

    /// minutes 为 nil 表示一直开着，直到手动关闭或退出 App。已经开着时只改时长。
    func start(minutes: Int?) {
        start(until: minutes.map { Date().addingTimeInterval(TimeInterval($0 * 60)) }, duration: minutes)
    }

    /// 自动更新重启前调用：记下是否开着，定时的还记下结束时间和选的时长。
    func saveForRestart() {
        guard isOn else { return }
        var state: [String: Any] = [:]
        if let end { state["end"] = end.timeIntervalSince1970 }
        if let duration { state["duration"] = duration }
        UserDefaults.standard.set(state, forKey: Self.restartKey)
    }

    /// 启动时调用：恢复更新前的防止休眠，定时的按原来的结束时间继续，已经过期就不恢复。
    func restoreAfterRestart() {
        let defaults = UserDefaults.standard
        guard let state = defaults.dictionary(forKey: Self.restartKey) else { return }
        defaults.removeObject(forKey: Self.restartKey)
        let end = (state["end"] as? Double).map(Date.init(timeIntervalSince1970:))
        guard end.map({ $0 > Date() }) ?? true else { return }
        start(until: end, duration: state["duration"] as? Int)
    }

    private func start(until end: Date?, duration: Int?) {
        guard lock.acquire() else { return }
        isOn = true
        self.duration = duration
        timer?.invalidate()
        timer = nil
        self.end = end
        guard end != nil else {
            minutesLeft = nil
            return
        }
        update()
        // 每 5 秒检查一次：既用来刷新剩余时间，也负责到点关闭，电脑休眠醒来后会立即补上。
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.update() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        end = nil
        duration = nil
        minutesLeft = nil
        lock.release()
        isOn = false
    }

    private func update() {
        guard let end else { return }
        let left = end.timeIntervalSinceNow
        guard left > 0 else {
            stop()
            Toasts.shared.show(L("防止休眠已结束"), icon: "cup.and.saucer")
            return
        }
        let minutes = Int((left / 60).rounded(.up))
        if minutes != minutesLeft { minutesLeft = minutes }
    }
}

/// 防止休眠的开关和时长选择，首页底部和快捷开关页都用这个弹出面板。
struct KeepAwakePanel: View {
    @ObservedObject private var keepAwake = KeepAwake.shared
    private static let minuteOptions = [15, 30, 45]
    private static let hourOptions = [1, 4, 8, 12]

    private func chip(_ label: String, minutes: Int?) -> some View {
        let selected = keepAwake.isOn && keepAwake.duration == minutes
        return Button { keepAwake.start(minutes: minutes) } label: {
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
                    get: { keepAwake.isOn },
                    set: { $0 ? keepAwake.start(minutes: nil) : keepAwake.stop() }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }
            Divider()
            HStack {
                Text(L("持续时间")).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
                Spacer()
                if let left = keepAwake.minutesLeft {
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
    @ObservedObject private var keepAwake = KeepAwake.shared
    @State private var showing = false

    private var label: String {
        guard keepAwake.isOn else { return L("防止休眠") }
        return keepAwake.minutesLeft.map { formatCompactDuration(minutes: $0) } ?? L("已开启")
    }

    var body: some View {
        Button { showing.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: keepAwake.isOn ? "cup.and.saucer.fill" : "cup.and.saucer")
                    .foregroundStyle(keepAwake.isOn ? Theme.blue : Theme.orange)
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
