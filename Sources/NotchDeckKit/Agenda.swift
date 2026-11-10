import AppKit
import EventKit
import SwiftUI

/// 读取系统日历里今天的日程。启动时只读取已授权的数据，绝不主动弹权限窗口。
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
            let calendar = Calendar.current
            let start = calendar.startOfDay(for: Date())
            guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return }
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

    /// 还没结束的日程，有具体时间的排在全天日程前面。
    static func upcoming(_ items: [Item], at date: Date) -> [Item] {
        items.filter { $0.end > date }.sorted {
            $0.isAllDay != $1.isAllDay ? !$0.isAllDay : $0.start < $1.start
        }
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

    static func countdown(to item: Item, at date: Date) -> String? {
        guard !item.isAllDay else { return nil }
        guard item.start > date else { return L("进行中") }
        let minutes = Int((item.start.timeIntervalSince(date) / 60).rounded(.up))
        return minutes < 60 ? L("%d 分钟后", minutes) : L("%d 小时后", minutes / 60)
    }
}

struct AgendaCard: View {
    @ObservedObject private var store = AgendaStore.shared
    private static let maxRows = 3

    private func header(countdown: String?) -> some View {
        Button(action: openCalendarApp) {
            CardHeader(L("今日日程"), symbol: "list.bullet.below.rectangle", color: Theme.coral) {
                if let countdown {
                    Text(countdown).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.teal).lineLimit(1).fixedSize()
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("打开日历"))
    }

    private func row(_ item: AgendaStore.Item, at date: Date) -> some View {
        HStack(spacing: 6) {
            Capsule().fill(Color(cgColor: item.color)).frame(width: 3, height: 14)
            Text(AgendaStore.timeLabel(item, at: date))
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
        .frame(height: 22)
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
                VStack(alignment: .leading, spacing: 3) {
                    header(countdown: upcoming.first.flatMap { AgendaStore.countdown(to: $0, at: timeline.date) })
                    if store.status != .fullAccess {
                        permissionPrompt
                    } else if upcoming.isEmpty {
                        message(L("今天没有更多日程"))
                    } else {
                        ForEach(upcoming.prefix(Self.maxRows)) { row($0, at: timeline.date) }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }
}
