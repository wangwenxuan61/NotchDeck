import SwiftUI

struct HomeCards: View {
    @ObservedObject var model: PanelModel
    @ObservedObject private var layout = CardLayoutStore.shared

    @ViewBuilder private func card(_ kind: CardKind) -> some View {
        switch kind {
        case .todo: TodoCard()
        case .note: NoteCard()
        case .clock: ClockCard()
        case .monitor: MonitorCard { model.page = .monitor }
        case .music: MusicCard()
        case .clipboard: ClipboardCard(model: model)
        case .timer: TimerCard(model: model)
        case .calendar: CalendarCard()
        case .lookBusy: LookBusyCard()
        case .agenda: AgendaCard()
        case .tokenUsage: TokenUsageCard(model: model)
        }
    }

    var body: some View {
        let pages = layout.visiblePages
        if pages.isEmpty {
            Button(L("首页没有卡片，点这里添加")) { model.page = .customize }
                .buttonStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let index = min(model.homePage, pages.count - 1)
            GeometryReader { proxy in
                let cards = pages[index]
                let available = proxy.size.width - 8 * CGFloat(cards.count - 1)
                let unit = available / cards.reduce(0) { $0 + $1.weight }
                HStack(spacing: 8) {
                    ForEach(cards) { kind in
                        card(kind).frame(width: unit * kind.weight)
                    }
                }
            }
            .id(index)
            .transition(.opacity)
        }
    }
}
