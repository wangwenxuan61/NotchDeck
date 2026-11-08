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

    private let store = EKEventStore()
    private var hiddenDone = Set<String>()
    private var generation = 0
    private var changeWork: DispatchWorkItem?

    private init() {
        selectedListID = UserDefaults.standard.string(forKey: Self.listKey) ?? ""
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            self?.scheduleReload()
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
        lists = store.calendars(for: .reminder).sorted { $0.title < $1.title }
        if store.calendar(withIdentifier: selectedListID) == nil {
            selectedListID = store.defaultCalendarForNewReminders()?.calendarIdentifier ?? lists.first?.calendarIdentifier ?? ""
        }
        guard currentList != nil else {
            Toasts.shared.show(L("提醒事项里没有可用列表"), icon: "exclamationmark.triangle")
            return
        }
        UserDefaults.standard.set(true, forKey: Self.enabledKey)
        isActive = true
        if movingLocalTodos {
            TodoStore.shared.takeLocalPendingTitles().forEach(add)
        }
        reload()
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
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.calendar = list
        save { try store.save(reminder, commit: true) }
    }

    func toggle(_ id: String) {
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else { return }
        reminder.isCompleted.toggle()
        hiddenDone.remove(id)
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
