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

    private let store = EKEventStore()
    private let queue = DispatchQueue(label: "notchdeck.agenda", qos: .utility)

    private static let meetingLink = try? NSRegularExpression(
        pattern: #"https?://(?:[\w-]+\.)*(?:zoom\.us/(?:j|my|w)/|meet\.google\.com/|teams\.microsoft\.com/l/meetup-join/|teams\.live\.com/meet/|webex\.com/|meeting\.tencent\.com/|voovmeeting\.com/|vc\.feishu\.cn/j/|larksuite\.com/vc/|meeting\.dingtalk\.com/)[^\s<>"')\]]*"#,
        options: .caseInsensitive
    )

    private init() {
        let center = NotificationCenter.default
        center.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in self?.refresh() }
        center.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        status = EKEventStore.authorizationStatus(for: .event)
        guard status == .fullAccess else {
            items = []
            return
        }
        queue.async { [weak self] in
            guard let self else { return }
            let calendar = Calendar.current
            let start = calendar.startOfDay(for: Date())
            guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return }
            let predicate = self.store.predicateForEvents(withStart: start, end: end, calendars: nil)
            let loaded = self.store.events(matching: predicate)
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
            store.requestFullAccessToEvents { [weak self] _, _ in
                DispatchQueue.main.async {
                    self?.store.refreshSourcesIfNecessary()
                    self?.refresh()
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

    private func openCalendar() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Calendar.app"))
    }

    private func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = LanguageStore.shared.locale
        formatter.setLocalizedDateFormatFromTemplate("jm")
        return formatter.string(from: date)
    }

    private func header(countdown: String?) -> some View {
        Button(action: openCalendar) {
            HStack(spacing: 5) {
                Image(systemName: "list.bullet.below.rectangle").foregroundStyle(Theme.coral)
                Text(L("今日日程")).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 4)
                if let countdown {
                    Text(countdown).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.teal).lineLimit(1).fixedSize()
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("打开日历"))
    }

    private func row(_ item: AgendaStore.Item) -> some View {
        HStack(spacing: 6) {
            Capsule().fill(Color(cgColor: item.color)).frame(width: 3, height: 14)
            Text(item.isAllDay ? L("全天") : time(item.start))
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
                        .background(Capsule().fill(Theme.blue))
                        .contentShape(Capsule())
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
                        ForEach(upcoming.prefix(Self.maxRows)) { row($0) }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }
}
