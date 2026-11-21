import SwiftUI

final class TodoStore: ObservableObject {
    static let shared = TodoStore()

    struct Item: Codable, Identifiable {
        var id = UUID().uuidString
        var title: String
        var done = false
        /// 手动设的提醒时间，到点前提醒。旧版本存的待办没有这个字段。
        var due: Date?
    }

    @Published private(set) var items: [Item]
    /// 还没添加的输入。面板收起后界面会拆掉，放在这里下次打开还在；不保存到文件。
    @Published var draft = ""
    /// 输入框旁设好的提醒时间，添加时带上。
    @Published var draftDue: Date?

    private static let file = "todos.json"
    private var sync: ReminderSync? { ReminderSync.shared.isActive ? ReminderSync.shared : nil }

    private init() { items = Storage.load([Item].self, from: Self.file) ?? [] }

    var pendingCount: Int { items.filter { !$0.done }.count }

    func add(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let due = draftDue
        draftDue = nil
        TodoReminders.shared.noteWritten(due)
        if let sync { sync.add(trimmed, due: due); return }
        items.insert(Item(title: trimmed, due: due), at: items.firstIndex { $0.done } ?? items.endIndex)
        persist()
    }

    func toggle(_ id: String) {
        if let sync { sync.toggle(id); return }
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items.remove(at: index)
        item.done.toggle()
        items.insert(item, at: item.done ? items.endIndex : (items.firstIndex { $0.done } ?? items.endIndex))
        persist()
    }

    func rename(_ id: String, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = items.firstIndex(where: { $0.id == id }), items[index].title != trimmed else { return }
        if let sync { sync.update(id, title: trimmed, due: items[index].due); return }
        items[index].title = trimmed
        persist()
    }

    /// 设置或去掉一条待办的提醒时间。
    func setDue(_ id: String, _ due: Date?) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].due != due else { return }
        TodoReminders.shared.noteWritten(due)
        if let sync { sync.update(id, title: items[index].title, due: due); return }
        items[index].due = due
        persist()
    }

    func remove(_ id: String) {
        if let sync { sync.remove(id); return }
        items.removeAll { $0.id == id }
        persist()
    }

    func clearDone() {
        if let sync { sync.hideDone(items.filter(\.done).map(\.id)); return }
        items.removeAll { $0.done }
        persist()
    }

    /// 同步开启时内存里是提醒事项的内容，所以这两个方法直接读写本地文件。
    func localPendingItems() -> [Item] {
        (Storage.load([Item].self, from: Self.file) ?? []).filter { !$0.done }
    }

    /// 只删除已经成功写入提醒事项的待办，反复开关同步也不会产生重复项。
    func removeLocalItems(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        var local = Storage.load([Item].self, from: Self.file) ?? []
        local.removeAll { ids.contains($0.id) }
        Storage.save(local, to: Self.file)
    }

    func showRemoteItems(_ remote: [Item]) { items = remote }

    func useLocalItems() { items = Storage.load([Item].self, from: Self.file) ?? [] }

    private func persist() { Storage.save(items, to: Self.file) }
}

struct TodoCard: View {
    @ObservedObject private var store = TodoStore.shared
    @ObservedObject private var reminders = ReminderSync.shared
    @FocusState private var focused: Bool
    @State private var hoveringInput = false
    /// 鼠标所在的那一条，右边显示删除按钮。
    @State private var hoveredID: String?
    @State private var editingID: String?
    @State private var editText = ""
    /// 正在设提醒时间的那一条；输入框旁的用 draftID。
    @State private var dueEditingID: String?
    private static let draftID = "draft"

    private func dueEditor(_ id: String) -> Binding<Bool> {
        Binding(get: { dueEditingID == id }, set: { if !$0, dueEditingID == id { dueEditingID = nil } })
    }
    @FocusState private var editing: Bool

    private func beginEdit(_ item: TodoStore.Item) {
        editText = item.title
        editingID = item.id
        // 输入框要先出现才能获得焦点。
        DispatchQueue.main.async { editing = true }
    }

    /// 回车或点到别处都会保存，内容为空时保持原样。
    private func commitEdit() {
        guard let id = editingID else { return }
        editingID = nil
        store.rename(id, to: editText)
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 5) {
                CardHeader(L("待办"), symbol: "checkmark.circle", color: Theme.teal) {
                    if reminders.isActive {
                        Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 10)).foregroundStyle(Theme.secondary)
                    }
                } trailing: {
                    HStack(spacing: 8) {
                        // 有打勾的才显示，一次清掉所有已完成的。
                        if store.items.contains(where: \.done) {
                            Button { store.clearDone() } label: {
                                Image(systemName: "checkmark.circle.badge.xmark")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.secondary)
                            }
                            .buttonStyle(.plain)
                            .help(L("清除已完成"))
                        }
                        Text("\(store.pendingCount)").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                    }
                }
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(store.items) { item in row(item) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.never)
                addRow
            }
        }
    }

    /// 输入行带“＋”和底色，一眼能看出可以输入。点“＋”或按回车添加，加完光标留在原处，可以接着输入下一条。
    private var addRow: some View {
        HStack(spacing: 6) {
            Button(action: submitDraft) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(store.draft.trimmingCharacters(in: .whitespaces).isEmpty ? Theme.tertiary : Theme.teal)
            }
            .buttonStyle(.plain)
            .help(L("添加"))
            TextField(L("添加待办"), text: $store.draft)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($focused)
                .onSubmit(submitDraft)
            Button { dueEditingID = Self.draftID } label: {
                if let due = store.draftDue {
                    TimeChip(due: due)
                } else {
                    Image(systemName: "alarm")
                        .font(.system(size: 12))
                        .foregroundStyle(hoveringInput || focused ? Theme.secondary : Theme.tertiary)
                }
            }
            .buttonStyle(.plain)
            .help(L("设置提醒时间"))
            .popover(isPresented: dueEditor(Self.draftID), arrowEdge: .bottom) {
                DueEditor(due: store.draftDue) { store.draftDue = $0; dueEditingID = nil }
            }
        }
        .padding(.horizontal, 7)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(focused || hoveringInput ? Theme.controlHover : Theme.control))
        .onHover { hoveringInput = $0 }
    }

    private func submitDraft() {
        store.add(store.draft)
        store.draft = ""
        // 回车后输入框可能会失去焦点，等这一轮更新完再放回去。
        DispatchQueue.main.async { focused = true }
    }

    private func delete(_ item: TodoStore.Item) {
        // 同步时会直接删掉系统“提醒事项”里的记录，没有撤销，先确认。
        guard !reminders.isActive || AppDelegate.shared.confirm(L("删除这条待办？"), message: L("它也会从系统“提醒事项”里删除。"), action: L("删除")) else { return }
        store.remove(item.id)
    }

    private func row(_ item: TodoStore.Item) -> some View {
        HStack(spacing: 5) {
            Button { store.toggle(item.id) } label: {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(item.done ? Theme.teal : Theme.secondary)
            }
            .buttonStyle(.plain)
            if editingID == item.id {
                TextField("", text: $editText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($editing)
                    .onSubmit(commitEdit)
            } else {
                Text(item.title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .strikethrough(item.done)
                    .foregroundStyle(item.done ? Theme.tertiary : Theme.primary)
                    .onTapGesture(count: 2) { beginEdit(item) }
                    .help(L("双击编辑"))
                Spacer(minLength: 4)
                if let due = item.due, !item.done {
                    Button { dueEditingID = item.id } label: { TimeChip(due: due) }
                        .buttonStyle(.plain)
                } else if hoveredID == item.id, !item.done {
                    Button { dueEditingID = item.id } label: {
                        Image(systemName: "alarm")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help(L("设置提醒时间"))
                }
                if hoveredID == item.id {
                    Button { delete(item) } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help(L("删除"))
                }
            }
        }
        .contentShape(Rectangle())
        .popover(isPresented: dueEditor(item.id), arrowEdge: .trailing) {
            DueEditor(due: item.due) { store.setDue(item.id, $0); dueEditingID = nil }
        }
        .onHover { inside in
            if inside { hoveredID = item.id } else if hoveredID == item.id { hoveredID = nil }
        }
        .onChange(of: editing) { _, isEditing in
            if !isEditing { commitEdit() }
        }
        .contextMenu {
            Button(L("编辑")) { beginEdit(item) }
            if !item.done {
                Button(L("设置提醒时间")) { dueEditingID = item.id }
            }
            if item.due != nil {
                Button(L("不提醒")) { store.setDue(item.id, nil) }
            }
            Button(L("删除")) { delete(item) }
            Button(L("清除已完成")) { store.clearDone() }
        }
    }
}

/// 待办行尾的时间：还早是灰色，快到了是橙色，过了是红色。每分钟刷新一次颜色和文字。
private struct TimeChip: View {
    let due: Date
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        TimelineView(.everyMinute) { context in
            let color = switch TodoTime.urgency(of: due, now: context.date, lead: settings.todoReminderLead) {
            case .later: Theme.secondary
            case .soon: Theme.orange
            case .overdue: Theme.coral
            }
            Text(TodoTime.label(due, now: context.date))
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
                .foregroundStyle(color)
                .padding(.horizontal, 5)
                .frame(height: 16)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(color.opacity(0.14)))
                .fixedSize()
                .help(localizedDateFormatter("yMMMdEEEjmm").string(from: due))
        }
    }
}

/// 设置提醒时间的小窗：上面选哪一天，中间调时和分，下面是快捷时间。样式和面板里的卡片、胶囊按钮一致。
private struct DueEditor: View {
    let original: Date?
    let commit: (Date?) -> Void
    @State private var day: Date
    @State private var hour: Int
    @State private var minute: Int
    /// 日期条往后翻了几周。
    @State private var weekOffset: Int
    /// 时和分可以点开直接输入，输入框里的文字单独存，离开时再整理成两位数。
    @State private var hourText: String
    @State private var minuteText: String
    @FocusState private var focus: Field?

    private enum Field { case hour, minute }

    private static var calendar: Calendar { Calendar.current }

    init(due: Date?, commit: @escaping (Date?) -> Void) {
        original = due
        self.commit = commit
        let start = due ?? TodoTime.suggested()
        let calendar = Self.calendar
        let today = calendar.startOfDay(for: Date())
        let day = calendar.startOfDay(for: start)
        _day = State(initialValue: day)
        _hour = State(initialValue: calendar.component(.hour, from: start))
        _minute = State(initialValue: calendar.component(.minute, from: start))
        _hourText = State(initialValue: String(format: "%02d", calendar.component(.hour, from: start)))
        _minuteText = State(initialValue: String(format: "%02d", calendar.component(.minute, from: start)))
        _weekOffset = State(initialValue: max(0, (calendar.dateComponents([.day], from: today, to: day).day ?? 0) / 7))
    }

    private var value: Date {
        Self.calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "alarm.fill").font(.system(size: 12)).foregroundStyle(Theme.orange)
                Text(L("提醒时间")).font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 4)
                TimelineView(.everyMinute) { context in
                    Text(TodoTime.distance(to: value, now: context.date))
                        .font(.system(size: 11))
                        .foregroundStyle(value <= context.date ? Theme.coral : Theme.secondary)
                        .monospacedDigit()
                }
            }
            dayStrip
            HStack(spacing: 4) {
                wheel(.hour, text: $hourText, up: { setHour((hour + 1) % 24) }, down: { setHour((hour + 23) % 24) })
                Text(verbatim: ":").font(.system(size: 28, weight: .light)).foregroundStyle(Theme.tertiary).offset(y: -2)
                wheel(.minute, text: $minuteText, up: { setMinute((minute / 5 + 1) * 5 % 60) },
                      down: { setMinute(minute % 5 == 0 ? (minute + 55) % 60 : minute - minute % 5) })
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).cardFill())
            HStack(spacing: 5) {
                ForEach(TodoTime.quickChoices(), id: \.title) { choice in
                    Button { commit(choice.date) } label: {
                        Text(choice.title)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                            .padding(.horizontal, 9)
                            .frame(height: 22)
                            .capsuleFill(Theme.control)
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                if original != nil {
                    Button { commit(nil) } label: {
                        Text(L("不提醒")).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.coral)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                PillButton(title: L("确定"), prominent: true, width: 72) { commit(value) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 292)
        .foregroundStyle(Theme.primary)
        .onChange(of: focus) { _, field in
            // 离开输入框时整理成两位数；点进输入框时全选，直接输入就会替换。
            if field != .hour { hourText = String(format: "%02d", hour) }
            if field != .minute { minuteText = String(format: "%02d", minute) }
            if field != nil {
                DispatchQueue.main.async { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) }
            }
        }
        // 小窗开着时，Esc 和点到面板外留给小窗自己，不收起整个面板。
        .onAppear { AppDelegate.shared.modalOpen = true }
        .onDisappear { AppDelegate.shared.modalOpen = false }
    }

    /// 一周七天，左右箭头翻周。今天和明天直接写字，其余显示星期几。
    private var dayStrip: some View {
        let calendar = Self.calendar
        let today = calendar.startOfDay(for: Date())
        let days = (0..<7).compactMap { calendar.date(byAdding: .day, value: weekOffset * 7 + $0, to: today) }
        return HStack(spacing: 3) {
            arrow("chevron.left", enabled: weekOffset > 0) { weekOffset -= 1 }
            ForEach(days, id: \.self) { date in
                let offset = calendar.dateComponents([.day], from: today, to: date).day ?? 0
                let selected = calendar.isDate(date, inSameDayAs: day)
                Button { day = date } label: {
                    VStack(spacing: 1) {
                        Text(offset == 0 ? L("今天") : offset == 1 ? L("明天") : localizedDateFormatter("EEE").string(from: date))
                            .font(.system(size: 9, weight: .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .foregroundStyle(selected ? Color.white.opacity(0.85) : Theme.secondary)
                        Text(verbatim: "\(calendar.component(.day, from: date))")
                            .font(.system(size: 14, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(selected ? Color.white : Theme.primary)
                    }
                    .frame(width: 32, height: 38)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(selected ? Theme.blue : Theme.control))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            arrow("chevron.right", enabled: true) { weekOffset += 1 }
        }
    }

    private func arrow(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(enabled ? Theme.secondary : Theme.tertiary.opacity(0.4))
                .frame(width: 14, height: 38)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func setHour(_ value: Int) {
        hour = value
        hourText = String(format: "%02d", value)
    }

    private func setMinute(_ value: Int) {
        minute = value
        minuteText = String(format: "%02d", value)
    }

    /// 只留数字，最多两位；合法时马上生效。时填满两位后跳到分。
    private func typed(_ field: Field, _ text: String) {
        let digits = String(text.filter { $0.isASCII && $0.isNumber }.prefix(2))
        if digits != text {
            if field == .hour { hourText = digits } else { minuteText = digits }
            return
        }
        guard let value = Int(digits) else { return }
        if field == .hour, value <= 23 {
            hour = value
            if digits.count == 2, focus == .hour { focus = .minute }
        } else if field == .minute, value <= 59 {
            minute = value
        }
    }

    /// 大号数字：点一下直接输入，也可以用上下箭头或 ↑↓ 键调整；分钟按 5 分钟一档。
    private func wheel(_ field: Field, text: Binding<String>, up: @escaping () -> Void, down: @escaping () -> Void) -> some View {
        VStack(spacing: 0) {
            stepper("chevron.up", action: up)
            TextField("", text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 30, weight: .medium, design: .rounded))
                .monospacedDigit()
                .multilineTextAlignment(.center)
                .focused($focus, equals: field)
                .frame(width: 56, height: 38)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(focus == field ? Theme.control : Color.clear))
                .onChange(of: text.wrappedValue) { _, new in typed(field, new) }
                .onSubmit { commit(value) }
                .onKeyPress(.upArrow) { up(); return .handled }
                .onKeyPress(.downArrow) { down(); return .handled }
            stepper("chevron.down", action: down)
        }
        .frame(width: 64)
    }

    private func stepper(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.secondary)
                .frame(width: 44, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .buttonRepeatBehavior(.enabled)
    }
}
