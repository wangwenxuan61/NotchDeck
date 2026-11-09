import AppKit

final class FocusTimer: ObservableObject {
    static let shared = FocusTimer()
    static let minutes = 25

    @Published private(set) var remaining: Int?
    private let clock = CountdownClock()

    private init() {
        clock.onChange = { [weak self] in self?.remaining = $0 }
        clock.onFinish = { [weak self] in self?.finish(completed: true) }
    }

    var running: Bool { remaining != nil }
    var label: String { Self.format(remaining ?? 0) }

    static func format(_ seconds: Int) -> String {
        String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    func toggle() {
        running ? finish(completed: false) : start()
    }

    private func start() {
        remaining = Self.minutes * 60
        clock.start(seconds: Self.minutes * 60)
        Self.runShortcut("NotchDeck 专注开始")
    }

    private func finish(completed: Bool) {
        clock.stop()
        remaining = nil
        Self.runShortcut("NotchDeck 专注结束")
        if completed {
            NSSound(named: "Glass")?.play()
            Toasts.shared.show(L("专注结束"), icon: "checkmark.circle")
        }
    }

    /// 系统没有开放勿扰接口；如果用户建了同名“快捷指令”，就由它来开关勿扰。
    private static func runShortcut(_ name: String) {
        DispatchQueue.global(qos: .utility).async {
            guard let data = Shell.output("/usr/bin/shortcuts", ["list"]) else { return }
            let names = String(decoding: data, as: UTF8.self).split(separator: "\n")
            guard names.contains(Substring(name)) else { return }
            Shell.launch("/usr/bin/shortcuts", ["run", name])
        }
    }
}

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
