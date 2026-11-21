import AppKit
import Combine
import SwiftUI

/// 待办的提醒时间由用户手动设置。这里是时间的显示和几个快捷选项。
enum TodoTime {
    enum Urgency { case later, soon, overdue }

    /// 打开时间选择时的默认值：下一个整点。
    static func suggested(now: Date = Date()) -> Date {
        let calendar = Calendar.current
        let hour = calendar.dateInterval(of: .hour, for: now)?.start ?? now
        return hour.addingTimeInterval(3600)
    }

    /// 时间选择里的快捷按钮：1 小时后（取整到 5 分钟）、今晚 8 点（已过 8 点就不给）、明天 9 点。
    static func quickChoices(now: Date = Date()) -> [(title: String, date: Date)] {
        let calendar = Calendar.current
        let inHour = now.addingTimeInterval(3600)
        let minute = calendar.component(.minute, from: inHour)
        let rounded = calendar.date(bySetting: .second, value: 0, of: inHour.addingTimeInterval(Double((5 - minute % 5) % 5 * 60))) ?? inHour
        var choices = [(L("1 小时后"), calendar.date(bySettingHour: calendar.component(.hour, from: rounded), minute: calendar.component(.minute, from: rounded), second: 0, of: rounded) ?? rounded)]
        if let evening = calendar.date(bySettingHour: 20, minute: 0, second: 0, of: now), evening > now {
            choices.append((L("今晚 8 点"), evening))
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)),
           let morning = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) {
            choices.append((L("明天 9 点"), morning))
        }
        return choices
    }

    /// 待办行尾的短标签：今天只显示时间，明天、昨天、一周内带上日子，更远的只显示日期。
    static func label(_ due: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let time = formatClockTime(due)
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: due)).day ?? 0
        switch days {
        case 0: return time
        case 1: return L("明天 %@", time)
        case -1: return L("昨天 %@", time)
        case 2..<7: return "\(localizedDateFormatter("EEE").string(from: due)) \(time)"
        default: return localizedDateFormatter("MMMd").string(from: due)
        }
    }

    /// 提醒卡片上的说明：还有多久，或者已经过了多久。
    static func distance(to due: Date, now: Date = Date()) -> String {
        let minutes = Int((due.timeIntervalSince(now) / 60).rounded())
        if minutes == 0 { return L("现在") }
        return minutes > 0 ? L("还有 %@", formatDuration(minutes: minutes)) : L("已过 %@", formatDuration(minutes: -minutes))
    }

    static func urgency(of due: Date, now: Date = Date(), lead: Int) -> Urgency {
        if due <= now { return .overdue }
        return due.timeIntervalSince(now) <= Double(max(lead, 30) * 60) ? .soon : .later
    }
}

/// 待办到点前弹提醒。只给最近的一条定一个闹钟，平时不做任何检查。
final class TodoReminders {
    static let shared = TodoReminders()
    static let snoozeMinutes = 10
    /// 错过太久的提醒（比如关机期间）不再补弹，只在待办上显示红色。
    static let missedWindow: TimeInterval = 30 * 60

    private let defaults = UserDefaults.standard
    private static let handledKey = "todoRemindersHandled"
    private static let snoozedKey = "todoRemindersSnoozed"
    /// 待办 id → 已经提醒过的那个时间。改了时间会重新提醒。
    private var handled: [String: Double] { didSet { defaults.set(handled, forKey: Self.handledKey) } }
    /// 待办 id → 稍后再提醒的时间。
    private var snoozed: [String: Double] { didSet { defaults.set(snoozed, forKey: Self.snoozedKey) } }
    /// 刚设的时间 → 设置的时刻。刚设的时间如果已经进入提前量，就等到点再提醒，不在设完时马上弹。
    private var justWritten: [Double: Date] = [:]
    private var timer: Timer?
    private var subscriptions: [AnyCancellable] = []

    private init() {
        handled = defaults.dictionary(forKey: Self.handledKey) as? [String: Double] ?? [:]
        snoozed = defaults.dictionary(forKey: Self.snoozedKey) as? [String: Double] ?? [:]
    }

    private var lead: TimeInterval { Double(AppSettings.shared.todoReminderLead * 60) }

    func start() {
        prune()
        // @Published 在赋值前就通知，等这一轮结束再读新的待办。
        let later: (Any) -> Void = { [weak self] _ in DispatchQueue.main.async { self?.reschedule() } }
        subscriptions = [
            TodoStore.shared.$items.sink(receiveValue: later),
            AppSettings.shared.$todoReminderLead.dropFirst().sink(receiveValue: later),
        ]
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.reschedule()
        }
        NotificationCenter.default.addObserver(forName: .NSSystemClockDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.reschedule()
        }
    }

    /// 设了提醒时间时调用。第一次用到时申请通知权限。
    func noteWritten(_ due: Date?) {
        guard let due else { return }
        justWritten[due.timeIntervalSince1970] = Date()
        SystemNotifier.shared.requestPermission()
    }

    func snooze(_ id: String) {
        snoozed[id] = Date().addingTimeInterval(Double(Self.snoozeMinutes * 60)).timeIntervalSince1970
        reschedule()
    }

    enum Decision: Equatable { case wait(Date), show, skip, remindAtDue }

    /// 一条待办现在该怎么处理。单独拿出来，检查程序可以直接验证。
    static func decide(due: Date, lead: TimeInterval, handled: Double?, snoozedUntil: Double?, justWritten: Bool, now: Date) -> Decision? {
        if let snoozedUntil {
            let time = Date(timeIntervalSince1970: snoozedUntil)
            return time > now ? .wait(time) : .show
        }
        guard handled != due.timeIntervalSince1970 else { return nil }
        let remindAt = due.addingTimeInterval(-lead)
        if remindAt > now { return .wait(remindAt) }
        if justWritten { return due > now ? .remindAtDue : .skip }
        return now.timeIntervalSince(due) > missedWindow ? .skip : .show
    }

    func reschedule() {
        timer?.invalidate()
        timer = nil
        let now = Date()
        justWritten = justWritten.filter { now.timeIntervalSince($0.value) < 60 }
        var next: Date?
        var due: [(TodoStore.Item, Date)] = []
        let pending = TodoStore.shared.items.filter { !$0.done }
        for item in pending {
            guard let date = item.due else { continue }
            let decision = Self.decide(due: date, lead: lead, handled: handled[item.id], snoozedUntil: snoozed[item.id],
                                       justWritten: justWritten[date.timeIntervalSince1970] != nil, now: now)
            switch decision {
            case .wait(let time): next = min(next ?? time, time)
            case .show: due.append((item, date))
            case .skip: markHandled(item.id, date)
            case .remindAtDue:
                snoozed[item.id] = date.timeIntervalSince1970
                next = min(next ?? date, date)
            case nil: break
            }
        }
        for (item, date) in due {
            markHandled(item.id, date)
            ReminderBanner.shared.show(item.id, title: item.title, due: date)
            SystemNotifier.shared.post(item.title, body: L("待办 · %@", TodoTime.label(date)))
        }
        // 已经完成或删掉的待办，卡片也收起来。
        ReminderBanner.shared.keepOnly(Set(pending.map(\.id)))
        guard let next else { return }
        let timer = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in self?.reschedule() }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func markHandled(_ id: String, _ due: Date) {
        handled[id] = due.timeIntervalSince1970
        snoozed[id] = nil
    }

    /// 两天前的记录用不上了，清掉免得越存越多。
    private func prune() {
        let cutoff = Date().addingTimeInterval(-2 * 86400).timeIntervalSince1970
        handled = handled.filter { $0.value > cutoff }
        snoozed = snoozed.filter { $0.value > cutoff }
    }
}

/// 刘海下面滑出的提醒卡片。同时到点的几条排队，一次显示一条。
final class ReminderBanner: ObservableObject {
    static let shared = ReminderBanner()
    static let width: CGFloat = 340

    struct Entry: Equatable { let id: String; let title: String; let due: Date }

    @Published private(set) var queue: [Entry] = []
    private var panel: NSPanel?

    func show(_ id: String, title: String, due: Date) {
        // 装忙时不弹卡片，免得露馅；系统通知照常发。
        guard !LookBusyController.shared.isShowing else { return }
        queue.removeAll { $0.id == id }
        queue.append(Entry(id: id, title: title, due: due))
        NSSound(named: "Glass")?.play()
        refresh()
    }

    func keepOnly(_ ids: Set<String>) {
        guard queue.contains(where: { !ids.contains($0.id) }) else { return }
        queue.removeAll { !ids.contains($0.id) }
        refresh()
    }

    func complete(_ entry: Entry) {
        dismiss(entry)
        TodoStore.shared.toggle(entry.id)
    }

    func snooze(_ entry: Entry) {
        dismiss(entry)
        TodoReminders.shared.snooze(entry.id)
    }

    func dismiss(_ entry: Entry) {
        queue.removeAll { $0 == entry }
        refresh()
    }

    /// 换了一条显示时高度可能变化，等界面更新完再按新大小摆放。
    private func refresh() {
        DispatchQueue.main.async { self.queue.isEmpty ? self.hide() : self.present() }
    }

    private func present() {
        let screen = AppDelegate.shared.screen(containing: NSEvent.mouseLocation)
        guard let visible = screen?.visibleFrame else { return }
        let panel = self.panel ?? makePanel()
        // 窗口大小由这里决定，不让界面自己撑大窗口：那样窗口会从底边往上长，盖住菜单栏。
        let height = NSHostingController(rootView: ReminderCard(banner: self)).sizeThatFits(in: NSSize(width: Self.width, height: 400)).height
        let size = NSSize(width: Self.width, height: ceil(height))
        let target = NSRect(x: visible.midX - size.width / 2, y: visible.maxY - Metrics.gapBelowMenuBar - size.height,
                            width: size.width, height: size.height)
        if panel.isVisible {
            panel.setFrame(target, display: true)
            return
        }
        panel.setFrame(target.offsetBy(dx: 0, dy: 12), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 1
        }
    }

    private func hide() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.16
            panel.animator().alphaValue = 0
        }, completionHandler: {
            if self.queue.isEmpty { panel.orderOut(nil) }
        })
    }

    private func makePanel() -> NSPanel {
        let panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 120),
                                  styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.appearance = AppSettings.shared.appearance.nsAppearance
        let host = NSHostingView(rootView: ReminderCard(banner: self))
        host.sizingOptions = []
        panel.contentView = host
        self.panel = panel
        return panel
    }
}

struct ReminderCard: View {
    @ObservedObject var banner: ReminderBanner
    /// 卡片四周留给阴影的透明区域。
    static let margin: CGFloat = 16

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        Group {
            if let entry = banner.queue.first {
                content(entry)
            } else {
                Color.clear.frame(height: 1)
            }
        }
        .frame(width: ReminderBanner.width - Self.margin * 2)
        .background {
            ZStack {
                VisualEffect(cornerRadius: 16)
                Theme.panelTint
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(Theme.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.22), radius: 10, y: 4)
        .padding([.horizontal, .bottom], Self.margin)
        .foregroundStyle(Theme.primary)
    }

    private func content(_ entry: ReminderBanner.Entry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "bell.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.orange)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Theme.orange.opacity(0.16)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(verbatim: "\(TodoTime.label(entry.due, now: context.date)) · \(TodoTime.distance(to: entry.due, now: context.date))")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.secondary)
                            .monospacedDigit()
                    }
                }
                Spacer(minLength: 0)
                if banner.queue.count > 1 {
                    Text(L("还有 %d 条", banner.queue.count - 1))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.secondary)
                        .padding(.horizontal, 6)
                        .frame(height: 18)
                        .capsuleFill(Theme.control)
                }
            }
            HStack(spacing: 6) {
                button(L("完成"), prominent: true) { banner.complete(entry) }
                button(L("%d 分钟后再提醒", TodoReminders.snoozeMinutes)) { banner.snooze(entry) }
                button(L("关闭")) { banner.dismiss(entry) }
            }
        }
        .padding(12)
    }

    private func button(_ title: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(prominent ? Color.white : Theme.primary)
                .frame(maxWidth: .infinity)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(prominent ? Theme.blue : Theme.control))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
