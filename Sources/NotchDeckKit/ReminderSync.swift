import AppKit
import EventKit

/// 打开同步后，待办卡片直接读写系统“提醒事项”的一个列表；关闭时不会改动提醒事项里的内容。
final class ReminderSync: ObservableObject {
    static let shared = ReminderSync()
    private static let enabledKey = "syncReminders"
    private static let listKey = "syncRemindersList"

    @Published private(set) var isActive = false
    @Published private(set) var lists: [EKCalendar] = []
    @Published var selectedListID: String {
        didSet {
            guard selectedListID != oldValue else { return }
            UserDefaults.standard.set(selectedListID, forKey: Self.listKey)
            reload()
        }
    }

    private static let hiddenKey = "syncRemindersHiddenDone"

    /// 授权前创建的 EKEventStore 在授权后可能仍然读不到列表，授权后会换一个新的。
    private var store = EKEventStore()
    /// 从卡片上隐藏的已完成项要保存下来，否则重启后今天完成的又会出现。
    private var hiddenDone: Set<String> {
        didSet { UserDefaults.standard.set(Array(hiddenDone), forKey: Self.hiddenKey) }
    }
    private var generation = 0
    private var changeWork: DispatchWorkItem?

    private init() {
        selectedListID = UserDefaults.standard.string(forKey: Self.listKey) ?? ""
        hiddenDone = Set(UserDefaults.standard.stringArray(forKey: Self.hiddenKey) ?? [])
        // store 授权后会换成新的，所以不按对象过滤，只处理当前这个 store 的变化。
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { [weak self] note in
            guard let self, note.object as? EKEventStore === self.store else { return }
            self.scheduleReload()
        }
    }

    /// 启动时只恢复已授权的同步，绝不主动弹权限窗口。
    func restore() {
        guard UserDefaults.standard.bool(forKey: Self.enabledKey),
              EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else { return }
        activate(movingLocalTodos: false)
    }

    func setEnabled(_ enabled: Bool) {
        if enabled {
            enable()
        } else {
            isActive = false
            UserDefaults.standard.set(false, forKey: Self.enabledKey)
            TodoStore.shared.useLocalItems()
        }
    }

    private func enable() {
        NSApp.activate(ignoringOtherApps: true)
        store.requestFullAccessToReminders { [weak self] granted, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if granted {
                    self.store = EKEventStore()
                    self.activate(movingLocalTodos: true)
                } else {
                    Toasts.shared.show(L("未获得提醒事项权限"), icon: "exclamationmark.triangle")
                    QuickControls.shared.openPrivacyPane("Privacy_Reminders")
                }
            }
        }
    }

    private func activate(movingLocalTodos: Bool) {
        store.refreshSourcesIfNecessary()
        // 共享或订阅的只读列表写不进去，不能作为同步目标。
        lists = store.calendars(for: .reminder).filter(\.allowsContentModifications).sorted { $0.title < $1.title }
        if !lists.contains(where: { $0.calendarIdentifier == selectedListID }) {
            let defaultID = store.defaultCalendarForNewReminders()?.calendarIdentifier
            selectedListID = (lists.first { $0.calendarIdentifier == defaultID } ?? lists.first)?.calendarIdentifier ?? ""
        }
        guard let list = currentList else {
            Toasts.shared.show(L("提醒事项里没有可用列表"), icon: "exclamationmark.triangle")
            return
        }
        UserDefaults.standard.set(true, forKey: Self.enabledKey)
        isActive = true
        if movingLocalTodos { moveLocalTodos(to: list) }
        reload()
    }

    /// 写入失败的待办留在本机，关闭同步后还能看到，下次开启时会再试一次。
    private func moveLocalTodos(to list: EKCalendar) {
        let pending = TodoStore.shared.localPendingItems()
        let moved = pending.filter { (try? createReminder($0.title, in: list)) != nil }
        TodoStore.shared.removeLocalItems(Set(moved.map(\.id)))
        if moved.count < pending.count {
            Toasts.shared.show(L("%d 条待办未能同步，已保留在本机", pending.count - moved.count), icon: "exclamationmark.triangle")
        }
    }

    private func createReminder(_ title: String, in list: EKCalendar) throws {
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.calendar = list
        try store.save(reminder, commit: true)
    }

    private var currentList: EKCalendar? { store.calendar(withIdentifier: selectedListID) }

    private func scheduleReload() {
        changeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reload() }
        changeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    func reload() {
        guard isActive, let list = currentList else { return }
        generation += 1
        let current = generation
        let startOfDay = Calendar.current.startOfDay(for: Date())
        let pending = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: [list])
        store.fetchReminders(matching: pending) { [weak self] incomplete in
            guard let self else { return }
            let done = self.store.predicateForCompletedReminders(withCompletionDateStarting: startOfDay, ending: nil, calendars: [list])
            self.store.fetchReminders(matching: done) { [weak self] completed in
                let pendingItems = (incomplete ?? [])
                    .sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
                    .map { TodoStore.Item(id: $0.calendarItemIdentifier, title: $0.title ?? "", done: false) }
                let doneItems = (completed ?? [])
                    .map { TodoStore.Item(id: $0.calendarItemIdentifier, title: $0.title ?? "", done: true) }
                DispatchQueue.main.async {
                    guard let self, self.isActive, current == self.generation else { return }
                    // 卡片只显示今天完成的项，其余的隐藏记录已经用不上，清掉免得越存越多。
                    let doneIDs = Set(doneItems.map(\.id))
                    if !self.hiddenDone.isSubset(of: doneIDs) { self.hiddenDone.formIntersection(doneIDs) }
                    TodoStore.shared.showRemoteItems(pendingItems + doneItems.filter { !self.hiddenDone.contains($0.id) })
                }
            }
        }
    }

    private func save(_ operation: () throws -> Void) {
        do {
            try operation()
        } catch {
            Toasts.shared.show(L("同步失败"), icon: "exclamationmark.triangle")
        }
        reload()
    }

    func add(_ title: String) {
        guard let list = currentList else { return }
        save { try createReminder(title, in: list) }
    }

    func toggle(_ id: String) {
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else { return }
        reminder.isCompleted.toggle()
        hiddenDone.remove(id)
        save { try store.save(reminder, commit: true) }
    }

    func rename(_ id: String, to title: String) {
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder, reminder.title != title else { return }
        reminder.title = title
        save { try store.save(reminder, commit: true) }
    }

    func remove(_ id: String) {
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else { return }
        save { try store.remove(reminder, commit: true) }
    }

    /// “清除已完成”只从卡片上隐藏，不删除提醒事项里的记录。
    func hideDone(_ ids: [String]) {
        hiddenDone.formUnion(ids)
        reload()
    }
}
