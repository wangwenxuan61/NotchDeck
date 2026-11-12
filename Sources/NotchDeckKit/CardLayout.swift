import AppKit
import SwiftUI

enum CardKind: String, Codable, CaseIterable, Identifiable {
    case todo, note, clock, monitor, music, clipboard, timer, calendar, lookBusy, agenda, tokenUsage, shelf, appTime

    var id: String { rawValue }

    var title: String {
        switch self {
        case .todo: return L("待办")
        case .note: return L("短记")
        case .clock: return L("时钟")
        case .monitor: return L("系统监控")
        case .music: return L("音乐")
        case .clipboard: return L("剪贴板")
        case .timer: return L("计时器")
        case .calendar: return L("月历")
        case .lookBusy: return L("装忙")
        case .agenda: return L("日程")
        case .tokenUsage: return L("Token 用量")
        case .shelf: return L("暂存架")
        case .appTime: return L("今日用时")
        }
    }

    var symbol: String {
        switch self {
        case .todo: return "checkmark.circle"
        case .note: return "note.text"
        case .clock: return "clock"
        case .monitor: return "gauge.with.dots.needle.33percent"
        case .music: return "music.note"
        case .clipboard: return "doc.on.clipboard"
        case .timer: return "timer"
        case .calendar: return "calendar"
        case .lookBusy: return "briefcase"
        case .agenda: return "list.bullet.below.rectangle"
        case .tokenUsage: return "chart.bar.xaxis"
        case .shelf: return "tray.full"
        case .appTime: return "hourglass"
        }
    }

    /// 同一页内各卡片按这个比例分配宽度。
    var weight: CGFloat {
        switch self {
        // 时钟卡片挪走后空出的位置给了待办和短记，监控和音乐卡片的宽度不变。
        case .todo, .note: return 1.35
        case .clock, .music, .timer: return 0.95
        case .monitor: return 1.75
        case .clipboard, .calendar, .lookBusy: return 1.1
        case .agenda: return 1.6
        case .tokenUsage, .shelf, .appTime: return 1.1
        }
    }
}

enum MoveDirection { case up, down, left, right }

final class CardLayoutStore: ObservableObject {
    static let shared = CardLayoutStore()
    static let maxPerPage = 5
    static let hiddenColumn = 2
    private static let file = "cards.json"
    private static let defaultPages: [[CardKind]] = [
        [.todo, .note, .monitor, .music],
        [.agenda, .clipboard, .shelf, .appTime],
    ]
    private static let agendaAddedKey = "cardsAddedAgenda"
    private static let clockMovedKey = "cardsMovedClockToTopBar"
    private static let scheduleShelfKey = "cardsScheduleAndShelf"
    private static let appTimeKey = "cardsAppTimeInsteadOfTimer"
    /// 只对已有布局做一次的调整。全新安装直接用默认布局，这些都算做过了。
    private static let oneTimeKeys = [agendaAddedKey, clockMovedKey, scheduleShelfKey, appTimeKey]

    @Published private(set) var pages: [[CardKind]]

    private init() {
        let defaults = UserDefaults.standard
        guard let saved = Storage.load([[CardKind]].self, from: Self.file) else {
            Self.oneTimeKeys.forEach { defaults.set(true, forKey: $0) }
            pages = Self.defaultPages
            return
        }
        var seen = Set<CardKind>()
        var cleaned = saved.prefix(2).map { page in
            Array(page.filter { seen.insert($0).inserted }.prefix(Self.maxPerPage))
        }
        while cleaned.count < 2 { cleaned.append([]) }
        let before = cleaned
        // 已经自定义过布局的用户，新卡片只自动加入一次；之后隐藏了也不再加回来。
        if !defaults.bool(forKey: Self.agendaAddedKey) {
            defaults.set(true, forKey: Self.agendaAddedKey)
            if !seen.contains(.agenda), cleaned[1].count < Self.maxPerPage { cleaned[1].insert(.agenda, at: 0) }
        }
        // 时间挪到了顶栏，时钟卡片对已有布局也只自动拿掉一次，想要的话可以在“首页卡片”里加回来。
        if !defaults.bool(forKey: Self.clockMovedKey) {
            defaults.set(true, forKey: Self.clockMovedKey)
            for index in cleaned.indices { cleaned[index].removeAll { $0 == .clock } }
        }
        if !defaults.bool(forKey: Self.scheduleShelfKey) {
            defaults.set(true, forKey: Self.scheduleShelfKey)
            cleaned = Self.useScheduleAndShelf(cleaned)
        }
        // 计时器在顶栏的计时页里也能一键开始，它的位置换成今日用时，同样只换一次。
        if !defaults.bool(forKey: Self.appTimeKey) {
            defaults.set(true, forKey: Self.appTimeKey)
            if !cleaned.joined().contains(.appTime) {
                cleaned = cleaned.map { $0.map { $0 == .timer ? .appTime : $0 } }
            }
        }
        pages = cleaned
        if cleaned != before { persist() }
    }

    /// 日程卡片已经包含本周日期，装忙的场景挪到了底部按钮，这两张卡片拿掉一次；空出来的位置放暂存架，
    /// 优先放在剪贴板后面。都可以在“首页卡片”里加回来或者再隐藏。
    static func useScheduleAndShelf(_ pages: [[CardKind]]) -> [[CardKind]] {
        var pages = pages
        var freed: (page: Int, index: Int)?
        for page in pages.indices {
            if let index = pages[page].firstIndex(where: { $0 == .calendar || $0 == .lookBusy }), freed == nil { freed = (page, index) }
            pages[page].removeAll { $0 == .calendar || $0 == .lookBusy }
        }
        guard !pages.joined().contains(.shelf) else { return pages }
        if let page = pages.firstIndex(where: { $0.contains(.clipboard) }), pages[page].count < maxPerPage,
           let index = pages[page].firstIndex(of: .clipboard) {
            pages[page].insert(.shelf, at: index + 1)
        } else if let freed, pages[freed.page].count < maxPerPage {
            pages[freed.page].insert(.shelf, at: min(freed.index, pages[freed.page].count))
        }
        return pages
    }

    var hidden: [CardKind] { CardKind.allCases.filter { kind in !pages.contains { $0.contains(kind) } } }
    var visiblePages: [[CardKind]] { pages.filter { !$0.isEmpty } }

    func items(in column: Int) -> [CardKind] {
        column == Self.hiddenColumn ? hidden : pages[column]
    }

    private func column(of kind: CardKind) -> Int {
        pages.firstIndex { $0.contains(kind) } ?? Self.hiddenColumn
    }

    func canMove(_ kind: CardKind, _ direction: MoveDirection) -> Bool {
        let current = column(of: kind)
        switch direction {
        case .up:
            return current != Self.hiddenColumn && pages[current].first != kind
        case .down:
            return current != Self.hiddenColumn && pages[current].last != kind
        case .left:
            return current > 0 && pages[current - 1].count < Self.maxPerPage
        case .right:
            return current == 1 || (current == 0 && pages[1].count < Self.maxPerPage)
        }
    }

    func move(_ kind: CardKind, _ direction: MoveDirection) {
        guard canMove(kind, direction) else { return }
        let current = column(of: kind)
        switch direction {
        case .up, .down:
            guard let index = pages[current].firstIndex(of: kind) else { return }
            pages[current].swapAt(index, direction == .up ? index - 1 : index + 1)
        case .left:
            if current != Self.hiddenColumn { pages[current].removeAll { $0 == kind } }
            pages[current - 1].append(kind)
        case .right:
            pages[current].removeAll { $0 == kind }
            if current == 0 { pages[1].append(kind) }
        }
        persist()
    }

    func reset() {
        pages = Self.defaultPages
        persist()
    }

    private func persist() { Storage.save(pages, to: Self.file) }
}

struct CustomizePage: View {
    @ObservedObject var model: PanelModel
    @ObservedObject private var store = CardLayoutStore.shared

    private func arrow(_ symbol: String, _ kind: CardKind, _ direction: MoveDirection) -> some View {
        let enabled = store.canMove(kind, direction)
        return Button { store.move(kind, direction) } label: {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(enabled ? Theme.primary : Theme.tertiary.opacity(0.5))
                .frame(width: 20, height: 20)
                .background(Circle().fill(enabled ? Theme.control : Color.clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func row(_ kind: CardKind) -> some View {
        HStack(spacing: 4) {
            Image(systemName: kind.symbol).font(.system(size: 11)).foregroundStyle(Theme.secondary).frame(width: 16)
            Text(kind.title).font(.system(size: 12)).lineLimit(1)
            Spacer(minLength: 2)
            arrow("chevron.up", kind, .up)
            arrow("chevron.down", kind, .down)
            arrow("chevron.left", kind, .left)
            arrow("chevron.right", kind, .right)
        }
    }

    private func column(_ title: String, _ index: Int) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title).font(.system(size: 12, weight: .semibold))
                    Spacer()
                    if index != CardLayoutStore.hiddenColumn {
                        Text("\(store.pages[index].count)/\(CardLayoutStore.maxPerPage)")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.secondary)
                            .monospacedDigit()
                    }
                }
                ScrollView(.vertical) {
                    VStack(spacing: 2) {
                        ForEach(store.items(in: index)) { row($0) }
                    }
                }
                .scrollIndicators(.never)
            }
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            PageHeader(title: L("首页卡片"), model: model, backTo: .settings) {
                Button(L("恢复默认")) { store.reset() }.buttonStyle(.plain).font(.system(size: 12))
            }
            HStack(spacing: 8) {
                column(L("第 1 页"), 0)
                column(L("第 2 页"), 1)
                column(L("不显示"), CardLayoutStore.hiddenColumn)
            }
        }
    }
}
