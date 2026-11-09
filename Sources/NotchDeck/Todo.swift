import SwiftUI

final class TodoStore: ObservableObject {
    static let shared = TodoStore()

    struct Item: Codable, Identifiable {
        var id = UUID().uuidString
        var title: String
        var done = false
    }

    @Published private(set) var items: [Item]

    private static let file = "todos.json"
    private var sync: ReminderSync? { ReminderSync.shared.isActive ? ReminderSync.shared : nil }

    private init() { items = Storage.load([Item].self, from: Self.file) ?? [] }

    var pendingCount: Int { items.filter { !$0.done }.count }

    func add(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let sync { sync.add(trimmed); return }
        items.insert(Item(title: trimmed), at: items.firstIndex { $0.done } ?? items.endIndex)
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
