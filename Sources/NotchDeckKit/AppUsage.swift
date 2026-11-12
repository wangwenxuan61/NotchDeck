import AppKit
import Combine
import SwiftUI

/// 记录每天各个 App 在前台用了多久。只记 Bundle ID 和秒数，存在本机，保留 7 天；
/// 只有首页放了“今日用时”卡片时才记录。切换 App 时记一笔，另外每分钟补记一次；
/// 5 分钟没有键盘鼠标操作、锁屏或休眠的时间不算。
final class AppUsageStore: ObservableObject {
    static let shared = AppUsageStore()
    static let idleThreshold: TimeInterval = 5 * 60
    static let keepDays = 7
    private static let file = "app-usage.json"
    /// 锁屏界面和屏幕保护程序不算在用。
    private static let ignored: Set<String> = ["com.apple.loginwindow", "com.apple.ScreenSaver.Engine"]

    /// 日期 -> Bundle ID -> 秒数。
    @Published private(set) var days: [String: [String: Double]]
    private var current: String?
    private var lastMark: Date?
    private var paused = false
    private var timer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var unsaved = 0
    private var layoutSubscription: AnyCancellable?

    private init() {
        days = Storage.load([String: [String: Double]].self, from: Self.file) ?? [:]
    }

    /// 启动时调用。首页上放着这张卡片才记录，拿掉后停止。
    func start() {
        layoutSubscription = CardLayoutStore.shared.$pages
            .map { $0.joined().contains(.appTime) }
            .removeDuplicates()
            .sink { [weak self] shown in shown ? self?.resume() : self?.stop() }
    }

    /// 打开面板时先把到现在为止的时间记上，卡片显示的才是最新的。
    func recordNow() {
        guard timer != nil else { return }
        record(until: Date(), idle: Self.idleSeconds())
    }

    func saveNow() {
        recordNow()
        save()
    }

    private func resume() {
        guard timer == nil else { return }
        activate(NSWorkspace.shared.frontmostApplication?.bundleIdentifier, at: Date(), idle: 0)
        let workspace = NSWorkspace.shared.notificationCenter
        func on(_ center: NotificationCenter, _ name: Notification.Name, _ action: @escaping (Notification) -> Void) {
            observers.append((center, center.addObserver(forName: name, object: nil, queue: .main, using: action)))
        }
        on(workspace, NSWorkspace.didActivateApplicationNotification) { [weak self] note in
            let app = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            self?.activate(app, at: Date(), idle: Self.idleSeconds())
        }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            on(workspace, name) { [weak self] _ in self?.pause(at: Date()) }
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            on(workspace, name) { [weak self] _ in self?.unpause(at: Date()) }
        }
        let distributed = DistributedNotificationCenter.default()
        on(distributed, Notification.Name("com.apple.screenIsLocked")) { [weak self] _ in self?.pause(at: Date()) }
        on(distributed, Notification.Name("com.apple.screenIsUnlocked")) { [weak self] _ in self?.unpause(at: Date()) }
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.recordNow() }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stop() {
        guard timer != nil else { return }
        recordNow()
        save()
        timer?.invalidate()
        timer = nil
        observers.forEach { $0.0.removeObserver($0.1) }
        observers = []
        current = nil
        lastMark = nil
    }

    // MARK: - 记账，检查程序直接调用

    /// 切到另一个 App：先把上一个 App 用到现在的时间记上。
    func activate(_ app: String?, at now: Date, idle: TimeInterval) {
        record(until: now, idle: idle)
        current = app.flatMap { Self.ignored.contains($0) ? nil : $0 }
    }

    func pause(at now: Date) {
        record(until: now, idle: 0)
        paused = true
    }

    func unpause(at now: Date) {
        paused = false
        lastMark = now
    }

    /// 把上次记账到 now 之间的时间算给当前 App。idle 是距离上次键盘鼠标操作的秒数：
    /// 超过 5 分钟没操作时，只算到停止操作后 5 分钟，读东西、看视频不算离开，走开了才不算。
    func record(until now: Date, idle: TimeInterval) {
        defer { if !paused { lastMark = now } }
        guard !paused, let last = lastMark, let app = current else { return }
        let end = idle > Self.idleThreshold ? now.addingTimeInterval(Self.idleThreshold - idle) : now
        let seconds = end.timeIntervalSince(last)
        guard seconds > 0 else { return }
        let day = UsageParsing.dayKey(for: last)
        days[day, default: [:]][app, default: 0] += seconds
        unsaved += 1
        if unsaved >= 5 { save() }
    }

    /// 某天各 App 的用时，用得多的在前。
    func usage(on date: Date = Date()) -> [(app: String, seconds: Double)] {
        (days[UsageParsing.dayKey(for: date)] ?? [:]).map { ($0.key, $0.value) }.sorted { $0.seconds > $1.seconds }
    }

    func reset() {
        days = [:]
        save()
    }

    private func save() {
        unsaved = 0
        let cutoff = UsageParsing.dayKey(for: Date().addingTimeInterval(-Double(Self.keepDays - 1) * 86_400))
        days = days.filter { $0.key >= cutoff }
        Storage.save(days, to: Self.file)
    }

    private static func idleSeconds() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    // MARK: - 显示用的名称和图标

    private static var infoCache: [String: (name: String, icon: NSImage)] = [:]

    static func info(for bundleID: String) -> (name: String, icon: NSImage) {
        if let cached = infoCache[bundleID] { return cached }
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        let name = url.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? bundleID
        let icon = url.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSWorkspace.shared.icon(for: .application)
        infoCache[bundleID] = (name, icon)
        return (name, icon)
    }
}

/// 首页卡片：今天用得最多的几个 App 和合计时长。
struct AppTimeCard: View {
    @ObservedObject private var store = AppUsageStore.shared
    private static let rows = 3

    private func row(_ app: String, seconds: Double, longest: Double) -> some View {
        let info = AppUsageStore.info(for: app)
        return VStack(spacing: 2) {
            HStack(spacing: 6) {
                Image(nsImage: info.icon).resizable().frame(width: 16, height: 16)
                Text(info.name).font(.system(size: 12)).lineLimit(1)
                Spacer(minLength: 4)
                Text(formatCompactDuration(minutes: Int(seconds / 60)))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(Theme.secondary)
                    .fixedSize()
            }
            GeometryReader { proxy in
                Capsule().fill(Theme.track)
                    .overlay(alignment: .leading) {
                        Capsule().fill(Theme.teal).frame(width: max(3, proxy.size.width * seconds / max(longest, 1)))
                    }
            }
            .frame(height: 3)
            .padding(.leading, 22)
        }
    }

    var body: some View {
        Card {
            let usage = store.usage().filter { $0.seconds >= 60 }
            let total = usage.reduce(0) { $0 + $1.seconds }
            VStack(alignment: .leading, spacing: 6) {
                CardHeader(L("今日用时"), symbol: "hourglass", color: Theme.teal) {
                    if total > 0 {
                        Text(formatCompactDuration(minutes: Int(total / 60)))
                            .font(.system(size: 12, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(Theme.secondary)
                    }
                }
                .help(L("只记录 App 名称和使用时长，保存在本机"))
                if usage.isEmpty {
                    Text(L("从现在开始记录，用一会儿再来看"))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ForEach(usage.prefix(Self.rows), id: \.app) { row($0.app, seconds: $0.seconds, longest: usage[0].seconds) }
                    Spacer(minLength: 0)
                }
            }
        }
        .onAppear { store.recordNow() }
    }
}
