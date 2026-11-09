import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct Card<Content: View>: View {
    var padding: CGFloat = 10
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).cardFill())
    }
}

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

struct TodoCard: View {
    @ObservedObject private var store = TodoStore.shared
    @ObservedObject private var reminders = ReminderSync.shared
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle").foregroundStyle(Theme.teal)
                    Text(L("待办")).font(.system(size: 13, weight: .semibold))
                    if reminders.isActive {
                        Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 10)).foregroundStyle(Theme.secondary)
                    }
                    Spacer()
                    Text("\(store.pendingCount)").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                }
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(store.items) { item in row(item) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.never)
                TextField(L("添加待办"), text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($focused)
                    .onSubmit {
                        store.add(draft)
                        draft = ""
                        focused = false
                    }
            }
        }
    }

    private func row(_ item: TodoStore.Item) -> some View {
        HStack(spacing: 5) {
            Button { store.toggle(item.id) } label: {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(item.done ? Theme.teal : Theme.secondary)
            }
            .buttonStyle(.plain)
            Text(item.title)
                .font(.system(size: 12))
                .lineLimit(1)
                .strikethrough(item.done)
                .foregroundStyle(item.done ? Theme.tertiary : Theme.primary)
        }
        .contextMenu {
            Button(L("删除")) { store.remove(item.id) }
            Button(L("清除已完成")) { store.clearDone() }
        }
    }
}

struct NoteCard: View {
    @ObservedObject private var store = NoteStore.shared

    private var color: Color { NoteStore.palette[min(store.colorIndex, NoteStore.palette.count - 1)].color }

    var body: some View {
        Card(padding: 8) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Image(systemName: "note.text").foregroundStyle(Theme.orange)
                    Text(L("短记")).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Menu {
                        ForEach(NoteStore.palette.indices, id: \.self) { index in
                            Button(L(NoteStore.palette[index].name)) { store.colorIndex = index }
                        }
                        Divider()
                        Button(L("清空")) { store.text = "" }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
                .padding(.horizontal, 2)

                TextEditor(text: $store.text)
                    .font(.system(size: 12))
                    .scrollContentBackground(.hidden)
                    .scrollIndicators(.never)
                    .foregroundStyle(Color.black.opacity(0.82))
                    .colorScheme(.light)
                    .padding(5)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(color))
            }
        }
    }
}

struct ClockCard: View {
    private var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = LanguageStore.shared.locale
        formatter.setLocalizedDateFormatFromTemplate("MMMdEEE")
        return formatter
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    var body: some View {
        Button {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Calendar.app"))
        } label: {
            Card {
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    VStack(spacing: 6) {
                        Text(dateFormatter.string(from: timeline.date))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.secondary)
                        Text(Self.timeFormatter.string(from: timeline.date))
                            .font(.system(size: 38, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .minimumScaleFactor(0.6)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .buttonStyle(.plain)
        .help(L("打开日历"))
    }
}

func formatTemperature(_ value: Double?) -> String? {
    value.map { "\(Int($0.rounded()))°C" }
}

struct Ring: View {
    let value: Double
    let color: Color

    var body: some View {
        ZStack {
            Circle().stroke(Theme.track, lineWidth: 4.5)
            Circle()
                .trim(from: 0, to: max(min(value, 1), 0.001))
                .stroke(color, style: StrokeStyle(lineWidth: 4.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int((value * 100).rounded()))%")
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
        }
        .frame(width: 40, height: 40)
        .animation(.easeOut(duration: 0.4), value: value)
    }
}

struct MonitorCard: View {
    @ObservedObject private var monitor = SystemMonitor.shared
    let onOpen: () -> Void

    private func column(_ title: String, value: Double, color: Color, detail: String?) -> some View {
        VStack(spacing: 3) {
            Ring(value: value, color: color)
            HStack(spacing: 4) {
                Text(title).foregroundStyle(Theme.secondary)
                if let detail { Text(detail).foregroundStyle(title == L("内存") ? Theme.secondary : Theme.teal) }
            }
            .font(.system(size: 11, weight: .medium))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }

    private var diskFraction: Double {
        monitor.diskTotal > 0 ? Double(monitor.diskUsed) / Double(monitor.diskTotal) : 0
    }

    private func gigabytes(_ bytes: Int64) -> String { "\(bytes / 1_000_000_000)G" }

    var body: some View {
        Button(action: onOpen) {
            Card {
                VStack(spacing: 5) {
                    HStack(spacing: 0) {
                        column("CPU", value: monitor.cpu, color: Theme.blue, detail: formatTemperature(monitor.cpuTemp))
                        column("GPU", value: monitor.gpu, color: Theme.purple, detail: formatTemperature(monitor.gpuTemp))
                        column(L("内存"), value: monitor.memory, color: Theme.orange, detail: L(monitor.memoryPressure))
                    }
                    VStack(spacing: 3) {
                        HStack {
                            Text(L("磁盘")).foregroundStyle(Theme.secondary)
                            Spacer()
                            Text("\(gigabytes(monitor.diskUsed)) / \(gigabytes(monitor.diskTotal))")
                                .foregroundStyle(Theme.secondary)
                                .monospacedDigit()
                            Text("\(Int((diskFraction * 100).rounded()))%").monospacedDigit()
                        }
                        .font(.system(size: 11, weight: .medium))
                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Theme.track)
                                Capsule().fill(Theme.orange).frame(width: proxy.size.width * diskFraction)
                            }
                        }
                        .frame(height: 5)
                    }
                    HStack(spacing: 10) {
                        Text(L("网速")).foregroundStyle(Theme.secondary)
                        Spacer()
                        Text("↓ \(formatSpeed(monitor.downloadSpeed))").monospacedDigit()
                        Text("↑ \(formatSpeed(monitor.uploadSpeed))").monospacedDigit()
                    }
                    .font(.system(size: 11, weight: .medium))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("查看监控详情"))
    }
}

struct MusicCard: View {
    @ObservedObject private var media = MediaController.shared

    private var hasMedia: Bool { !media.title.isEmpty }

    private func control(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15)).frame(width: 28, height: 34).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Image(systemName: "music.note").foregroundStyle(Theme.coral)
                    Text(hasMedia ? media.title : L("未在播放"))
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                }
                Text(media.artist.isEmpty ? " " : media.artist)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                HStack(spacing: 0) {
                    control("backward.fill") { media.previous() }
                    Spacer(minLength: 0)
                    Button { media.togglePlayPause() } label: {
                        Image(systemName: media.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(Theme.coral))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    Spacer(minLength: 0)
                    control("forward.fill") { media.next() }
                }
                .opacity(hasMedia ? 1 : 0.45)
                .disabled(!hasMedia)
            }
        }
    }
}

struct DockRow: View {
    @ObservedObject var model: PanelModel
    @ObservedObject private var store = DockStore.shared
    @State private var dragging: String?

    private func collapse() {
        AppDelegate.shared.closePanel()
    }

    private var busyButton: some View {
        Button { LookBusyController.shared.show() } label: {
            HStack(spacing: 6) {
                Image(systemName: "briefcase.fill").foregroundStyle(Theme.purple)
                Text(L("装忙")).font(.system(size: 13, weight: .medium)).lineLimit(1).fixedSize()
            }
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(Capsule().fill(Theme.control))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(L("全屏装忙（⌃⌥B）"))
    }

    private var divider: some View {
        Rectangle().fill(Theme.track).frame(width: 1, height: 30)
    }

    var body: some View {
        HStack(spacing: 12) {
            busyButton
            divider
            HStack(spacing: 0) {
                ForEach(store.items.prefix(DockStore.visibleCount)) { app in
                    AppIcon(app: app, size: 38) { collapse() }
                        .frame(maxWidth: .infinity)
                        .onDrag {
                            dragging = app.path
                            return NSItemProvider(object: app.path as NSString)
                        }
                        .onDrop(of: [.text], delegate: DockDropDelegate(target: app.path, dragging: $dragging))
                        .contextMenu { Button(L("从快捷栏移除")) { store.unpin(app.path) } }
                }
                IconButton(symbol: "ellipsis", help: L("全部快捷 App")) { model.page = .pinned }
                    .padding(.horizontal, 8)
            }
            divider
            IconButton(symbol: "circle.grid.3x3.fill", help: L("所有应用")) { model.page = .apps }
        }
    }
}

struct DockDropDelegate: DropDelegate {
    let target: String
    @Binding var dragging: String?

    func dropEntered(info: DropInfo) {
        guard let dragging else { return }
        withAnimation(.easeOut(duration: 0.15)) { DockStore.shared.move(dragging, before: target) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

struct AppIcon: View {
    let app: AppEntry
    let size: CGFloat
    var afterLaunch: () -> Void = {}
    @State private var hovering = false

    var body: some View {
        Button {
            app.launch()
            afterLaunch()
        } label: {
            Image(nsImage: app.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .scaleEffect(hovering ? 1.1 : 1)
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
        .buttonStyle(.plain)
        .help(app.name)
        .onHover { hovering = $0 }
    }
}
