import AppKit
import EventKit
import SwiftUI

/// 读取系统日历里本周和接下来一周的日程。启动时只读取已授权的数据，绝不主动弹权限窗口。
final class AgendaStore: ObservableObject {
    static let shared = AgendaStore()

    struct Item: Identifiable, Equatable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        let isAllDay: Bool
        let color: CGColor
        let joinURL: URL?
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var status = EKEventStore.authorizationStatus(for: .event)

    /// 授权前创建的 EKEventStore 在授权后可能仍然读不到数据，授权后会换一个新的。
    private var store = EKEventStore()
    private let queue = DispatchQueue(label: "notchdeck.agenda", qos: .utility)

    private static let meetingLink = try? NSRegularExpression(
        pattern: #"https?://(?:[\w-]+\.)*(?:zoom\.us/(?:j|my|w)/|meet\.google\.com/|teams\.microsoft\.com/l/meetup-join/|teams\.live\.com/meet/|webex\.com/|meeting\.tencent\.com/|voovmeeting\.com/|vc\.feishu\.cn/j/|larksuite\.com/vc/|meeting\.dingtalk\.com/)[^\s<>"')\]]*"#,
        options: .caseInsensitive
    )

    private init() {
        let center = NotificationCenter.default
        center.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { [weak self] note in
            guard let self, note.object as? EKEventStore === self.store else { return }
            self.refresh()
        }
        center.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        var current = EKEventStore.authorizationStatus(for: .event)
        if current == .notDetermined || current == .denied {
            // App 运行期间刚授权（弹窗里允许，或在系统设置里打开）时，系统返回的状态可能还停在旧值，要重启 App 才更新。
            // 新建一个 EKEventStore 实际读一下日历列表，能读到就是已经有权限了。
            let probe = EKEventStore()
            if !probe.calendars(for: .event).isEmpty {
                store = probe
                current = .fullAccess
            }
        }
        status = current
        guard status == .fullAccess else {
            items = []
            return
        }
        let store = store
        queue.async { [weak self] in
            guard let self else { return }
            // 从本周第一天读到 7 天后：本周的日期条要标出哪天有日程，列表要能接着显示之后几天的。
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: Date())
            let start = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
            guard let end = calendar.date(byAdding: .day, value: Self.lookAheadDays + 1, to: today) else { return }
            let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
            let loaded = store.events(matching: predicate)
                .filter { $0.attendees?.first(where: \.isCurrentUser)?.participantStatus != .declined }
                .map(Self.item)
            DispatchQueue.main.async {
                if loaded != self.items { self.items = loaded }
            }
        }
    }

    func connect() {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined:
            NSApp.activate(ignoringOtherApps: true)
            store.requestFullAccessToEvents { [weak self] granted, _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if granted { self.store = EKEventStore() }
                    self.refresh()
                }
            }
        default:
            QuickControls.shared.openPrivacyPane("Privacy_Calendars")
        }
    }

    private static func item(_ event: EKEvent) -> Item {
        Item(
            id: "\(event.eventIdentifier ?? UUID().uuidString)-\(event.startDate.timeIntervalSince1970)",
            title: event.title ?? "",
            start: event.startDate,
            end: event.endDate,
            isAllDay: event.isAllDay,
            color: event.calendar.cgColor,
            joinURL: joinURL(in: [event.url?.absoluteString, event.location, event.notes])
        )
    }

    /// 会议链接可能写在 URL、地点或备注里，只识别常见的会议服务，避免把普通网址当成会议。
    static func joinURL(in sources: [String?]) -> URL? {
        guard let meetingLink else { return nil }
        for text in sources.compactMap({ $0 }) {
            let range = NSRange(text.startIndex..., in: text)
            guard let match = meetingLink.firstMatch(in: text, range: range), let found = Range(match.range, in: text) else { continue }
            let link = text[found].trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
            if let url = URL(string: link) { return url }
        }
        return nil
    }

    /// 列表往后看几天。
    static let lookAheadDays = 7

    /// 还没结束的日程，按日期排；同一天里有具体时间的排在全天日程前面。已经开始的算在今天。
    static func upcoming(_ items: [Item], at date: Date) -> [Item] {
        let calendar = Calendar.current
        func day(_ item: Item) -> Date { calendar.startOfDay(for: max(item.start, date)) }
        return items.filter { $0.end > date }.sorted {
            let (a, b) = (day($0), day($1))
            if a != b { return a < b }
            return $0.isAllDay != $1.isAllDay ? !$0.isAllDay : $0.start < $1.start
        }
    }

    /// 今天的日程只写时间，之后的前面加上“明天”或星期几。
    static func whenLabel(_ item: Item, at date: Date) -> String {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: max(item.start, date))
        let today = calendar.startOfDay(for: date)
        guard day > today else { return timeLabel(item, at: date) }
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)
        let name = day == tomorrow ? L("明天") : localizedDateFormatter("EEE").string(from: day)
        return name + " " + (item.isAllDay ? L("全天") : formatClockTime(item.start))
    }

    /// 有日程的日子，用来在日期条上标一个点。跨天的日程每一天都算。
    static func busyDays(_ items: [Item]) -> Set<Date> {
        let calendar = Calendar.current
        var days = Set<Date>()
        for item in items {
            var day = calendar.startOfDay(for: item.start)
            // 全天日程的结束时间是第二天零点，不算那一天。
            let last = item.end.addingTimeInterval(-1)
            while day <= last, days.count < 400 {
                days.insert(day)
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
        }
        return days
    }

    /// 今天之前开始的日程显示今天的结束时间；整天都在进行中的按全天显示。
    static func timeLabel(_ item: Item, at date: Date) -> String {
        guard !item.isAllDay else { return L("全天") }
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: date)
        guard item.start < startOfToday else { return formatClockTime(item.start) }
        guard let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday) else { return L("全天") }
        return item.end < startOfTomorrow ? L("至 %@", formatClockTime(item.end)) : L("全天")
    }

    /// 一天以内才显示倒计时，更远的看列表里的日期就够了。
    static func countdown(to item: Item, at date: Date) -> String? {
        guard !item.isAllDay, item.start.timeIntervalSince(date) < 24 * 3600 else { return nil }
        guard item.start > date else { return L("进行中") }
        let minutes = Int((item.start.timeIntervalSince(date) / 60).rounded(.up))
        return minutes < 60 ? L("%d 分钟后", minutes) : L("%d 小时后", minutes / 60)
    }
}

/// 日程卡片：上面是本周的日期条，下面是接下来的日程。今天的过完了就接着显示之后几天的，不会空着。
struct AgendaCard: View {
    @ObservedObject private var store = AgendaStore.shared
    private static let maxRows = 2

    private func header(countdown: String?) -> some View {
        Button(action: openCalendarApp) {
            CardHeader(L("日程"), symbol: "calendar", color: Theme.coral) {
                if let countdown {
                    Text(countdown).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.teal).lineLimit(1).fixedSize()
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("打开日历"))
    }

    private func weekStrip(at date: Date) -> some View {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: date)
        let start = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        let days = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
        let busy = AgendaStore.busyDays(store.items)
        let symbols = localizedDateFormatter("EEEEE")
        return HStack(spacing: 0) {
            ForEach(days, id: \.self) { day in
                let isToday = day == today
                VStack(spacing: 1) {
                    Text(symbols.string(from: day)).font(.system(size: 9, weight: .medium)).foregroundStyle(Theme.secondary)
                    Text("\(calendar.component(.day, from: day))")
                        .font(.system(size: 11, weight: isToday ? .bold : .regular))
                        .monospacedDigit()
                        .foregroundStyle(isToday ? Color.white : (day < today ? Theme.tertiary : Theme.primary))
                        .frame(width: 20, height: 16)
                        .background(RoundedRectangle(cornerRadius: 5).fill(isToday ? Theme.coral : Color.clear))
                    Circle().fill(busy.contains(day) && !isToday ? Theme.coral : Color.clear).frame(width: 3, height: 3)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func row(_ item: AgendaStore.Item, at date: Date) -> some View {
        HStack(spacing: 6) {
            Capsule().fill(Color(cgColor: item.color)).frame(width: 3, height: 14)
            Text(AgendaStore.whenLabel(item, at: date))
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
                .fixedSize()
            Text(item.title).font(.system(size: 12)).lineLimit(1)
            Spacer(minLength: 0)
            if let url = item.joinURL {
                Button {
                    AppDelegate.shared.closePanel()
                    NSWorkspace.shared.open(url)
                } label: {
                    Text(L("加入"))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 7)
                        .frame(height: 18)
                        .capsuleFill(Theme.blue)
                }
                .buttonStyle(.plain)
                .help(url.host ?? "")
            }
        }
        .frame(height: 20)
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Theme.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var permissionPrompt: some View {
        Button(store.status == .notDetermined ? L("连接日历") : L("去系统设置授权")) { store.connect() }
            .controlSize(.small)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var body: some View {
        Card {
            TimelineView(.everyMinute) { timeline in
                let upcoming = AgendaStore.upcoming(store.items, at: timeline.date)
                VStack(alignment: .leading, spacing: 4) {
                    header(countdown: upcoming.first.flatMap { AgendaStore.countdown(to: $0, at: timeline.date) })
                    weekStrip(at: timeline.date)
                    Rectangle().fill(Theme.hairline).frame(height: 1)
                    if store.status != .fullAccess {
                        permissionPrompt
                    } else if upcoming.isEmpty {
                        message(L("接下来 7 天没有日程"))
                    } else {
                        ForEach(upcoming.prefix(Self.maxRows)) { row($0, at: timeline.date) }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }
}
