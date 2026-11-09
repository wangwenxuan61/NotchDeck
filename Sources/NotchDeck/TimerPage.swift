import AppKit
import SwiftUI

/// 倒计时和专注共用的走时逻辑。按结束时刻计算，电脑休眠或定时器延迟都不会让剩余时间变多。
final class CountdownClock {
    var onChange: ((Int) -> Void)?
    var onFinish: (() -> Void)?

    private var end: Date?
    private var timer: Timer?
    private var reported: Int?

    func start(seconds: Int) {
        end = Date().addingTimeInterval(TimeInterval(seconds))
        reported = seconds
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        end = nil
    }

    private func tick() {
        guard let end else { return }
        let left = Int(end.timeIntervalSinceNow.rounded(.up))
        if left <= 0 {
            stop()
            onFinish?()
        } else if left != reported {
            reported = left
            onChange?(left)
        }
    }
}

final class CountdownTimer: ObservableObject {
    static let shared = CountdownTimer()
    static let presets = [1, 3, 5, 10, 15, 30]
    private static let minutesKey = "countdownMinutes"

    @Published private(set) var remaining: Int?
    @Published private(set) var isPaused = false
    @Published private(set) var total = 0
    @Published var minutes: Int {
        didSet { UserDefaults.standard.set(minutes, forKey: Self.minutesKey) }
    }

    private let clock = CountdownClock()

    private init() {
        minutes = UserDefaults.standard.object(forKey: Self.minutesKey) as? Int ?? 5
        clock.onChange = { [weak self] in self?.remaining = $0 }
        clock.onFinish = { [weak self] in
            self?.reset()
            NSSound(named: "Glass")?.play()
            Toasts.shared.show(L("计时结束"), icon: "timer")
        }
    }

    var isActive: Bool { remaining != nil }
    var progress: Double {
        guard let remaining, total > 0 else { return 1 }
        return Double(remaining) / Double(total)
    }

    func start(seconds: Int) {
        total = seconds
        remaining = seconds
        isPaused = false
        clock.start(seconds: seconds)
    }

    func togglePause() {
        guard let remaining else { return }
        if isPaused {
            isPaused = false
            clock.start(seconds: remaining)
        } else {
            isPaused = true
            clock.stop()
        }
    }

    func reset() {
        clock.stop()
        remaining = nil
        isPaused = false
    }
}

final class Stopwatch: ObservableObject {
    static let shared = Stopwatch()

    @Published private(set) var isRunning = false
    @Published private(set) var laps: [TimeInterval] = []
    private var accumulated: TimeInterval = 0
    private var started: Date?

    func elapsed(at date: Date) -> TimeInterval {
        accumulated + (started.map { date.timeIntervalSince($0) } ?? 0)
    }

    func toggle() {
        if isRunning {
            accumulated = elapsed(at: Date())
            started = nil
        } else {
            started = Date()
        }
        isRunning.toggle()
    }

    func lap() { laps.insert(elapsed(at: Date()), at: 0) }

    func reset() {
        isRunning = false
        accumulated = 0
        started = nil
        laps = []
    }

    static func format(_ value: TimeInterval) -> String {
        let tenths = Int(value * 10)
        return String(format: "%02d:%02d.%d", tenths / 600, (tenths / 10) % 60, tenths % 10)
    }
}

struct PillButton: View {
    let title: String
    var symbol: String?
    var prominent = false
    var width: CGFloat?
    var horizontalPadding: CGFloat = 10
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol) }
                Text(title).lineLimit(1).minimumScaleFactor(0.7)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(prominent ? Color.white : Theme.primary)
            .padding(.horizontal, horizontalPadding)
            .frame(width: width, height: 26)
            .background(Capsule().fill(prominent ? Theme.blue : Theme.control))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct CountdownPanel: View {
    @ObservedObject private var countdown = CountdownTimer.shared

    private func step(_ symbol: String, delta: Int) -> some View {
        Button { countdown.minutes = min(max(countdown.minutes + delta, 1), 180) } label: {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 26, height: 26)
                .background(Circle().fill(Theme.control))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private var ring: some View {
        ZStack {
            Circle().stroke(Theme.track, lineWidth: 6)
            Circle()
                .trim(from: 0, to: max(countdown.progress, 0.001))
                .stroke(Theme.blue, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.25), value: countdown.progress)
            Text(FocusTimer.format(countdown.remaining ?? countdown.minutes * 60))
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .padding(.horizontal, 10)
        }
        .frame(width: 118, height: 118)
    }

    private var idleControls: some View {
        VStack(spacing: 8) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(CountdownTimer.presets, id: \.self) { value in
                    Button { countdown.minutes = value } label: {
                        Text(L("%d 分", value))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(countdown.minutes == value ? Theme.blue : Theme.primary)
                            .frame(maxWidth: .infinity, minHeight: 26)
                            .background(Capsule().fill(countdown.minutes == value ? Theme.blue.opacity(0.16) : Theme.control))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(spacing: 6) {
                step("minus", delta: -1)
                Text(L("%d 分钟", countdown.minutes))
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .frame(minWidth: 52)
                step("plus", delta: 1)
                Spacer(minLength: 0)
                PillButton(title: L("开始"), symbol: "play.fill", prominent: true) {
                    countdown.start(seconds: countdown.minutes * 60)
                }
            }
        }
    }

    private var activeControls: some View {
        VStack(spacing: 10) {
            Text(countdown.isPaused ? L("已暂停") : L("倒计时中"))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.secondary)
            HStack(spacing: 8) {
                PillButton(title: countdown.isPaused ? L("继续") : L("暂停"), symbol: countdown.isPaused ? "play.fill" : "pause.fill", prominent: true, width: 86) {
                    countdown.togglePause()
                }
                PillButton(title: L("取消"), width: 66) { countdown.reset() }
            }
        }
        .frame(maxWidth: .infinity)
    }

    var body: some View {
        Card(padding: 10) {
            HStack(spacing: 16) {
                ring
                if countdown.isActive { activeControls } else { idleControls }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct StopwatchPanel: View {
    @ObservedObject private var stopwatch = Stopwatch.shared

    var body: some View {
        Card {
            VStack(spacing: 6) {
                HStack {
                    Text(L("秒表")).font(.system(size: 13, weight: .semibold))
                    Spacer()
                }
                TimelineView(.animation(minimumInterval: 0.1, paused: !stopwatch.isRunning)) { timeline in
                    Text(Stopwatch.format(stopwatch.elapsed(at: timeline.date)))
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
                HStack(spacing: 8) {
                    PillButton(title: stopwatch.isRunning ? L("暂停") : L("开始"), prominent: true, width: 88) { stopwatch.toggle() }
                    if stopwatch.isRunning {
                        PillButton(title: L("计次"), width: 88) { stopwatch.lap() }
                    } else {
                        PillButton(title: L("复位"), width: 88) { stopwatch.reset() }
                    }
                }
                ScrollView(.vertical) {
                    VStack(spacing: 2) {
                        ForEach(Array(stopwatch.laps.enumerated()), id: \.offset) { index, lap in
                            HStack {
                                Text(L("计次 %d", stopwatch.laps.count - index)).foregroundStyle(Theme.secondary)
                                Spacer()
                                Text(Stopwatch.format(lap)).monospacedDigit()
                            }
                            .font(.system(size: 11))
                        }
                    }
                }
                .scrollIndicators(.never)
            }
        }
    }
}

struct FocusPanel: View {
    @ObservedObject private var focus = FocusTimer.shared

    var body: some View {
        Card {
            VStack(spacing: 8) {
                HStack {
                    Text(L("专注")).font(.system(size: 13, weight: .semibold))
                    Spacer()
                }
                Spacer(minLength: 0)
                Text(focus.running ? focus.label : FocusTimer.format(FocusTimer.minutes * 60))
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(focus.running ? Theme.teal : Theme.primary)
                Spacer(minLength: 0)
                PillButton(title: focus.running ? L("结束") : L("开始专注"), prominent: !focus.running, width: 96) { focus.toggle() }
            }
        }
    }
}

struct TimerPage: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        VStack(spacing: 6) {
            PageHeader(title: L("计时器"), model: model)
            HStack(spacing: 8) {
                CountdownPanel().frame(maxWidth: .infinity)
                StopwatchPanel().frame(width: 230)
                FocusPanel().frame(width: 150)
            }
        }
    }
}

struct TimerCard: View {
    @ObservedObject var model: PanelModel
    @ObservedObject private var countdown = CountdownTimer.shared

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                Button { model.page = .timer } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "timer").foregroundStyle(Theme.blue)
                        Text(L("计时器")).font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
                if let remaining = countdown.remaining {
                    Text(FocusTimer.format(remaining))
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .frame(maxWidth: .infinity)
                    Spacer(minLength: 0)
                    HStack(spacing: 6) {
                        PillButton(title: countdown.isPaused ? L("继续") : L("暂停"), prominent: true, horizontalPadding: 6) { countdown.togglePause() }
                        PillButton(title: L("取消"), horizontalPadding: 6) { countdown.reset() }
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    // 这张卡片和其他四张同页时很窄，内边距要收紧，否则分钟数显示不全。
                    HStack(spacing: 4) {
                        ForEach([5, 10, 25], id: \.self) { value in
                            PillButton(title: L("%d 分", value), horizontalPadding: 4) { countdown.start(seconds: value * 60) }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    Spacer(minLength: 0)
                }
            }
        }
    }
}
