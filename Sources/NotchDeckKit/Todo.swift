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

    func rename(_ id: String, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let sync { sync.rename(id, to: trimmed); return }
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].title != trimmed else { return }
        items[index].title = trimmed
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
    @State private var hoveringInput = false
    @State private var editingID: String?
    @State private var editText = ""
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
                    Text("\(store.pendingCount)").font(.system(size: 13)).foregroundStyle(Theme.secondary)
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
                    .foregroundStyle(draft.trimmingCharacters(in: .whitespaces).isEmpty ? Theme.tertiary : Theme.teal)
            }
            .buttonStyle(.plain)
            .help(L("添加"))
            TextField(L("添加待办"), text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($focused)
                .onSubmit(submitDraft)
        }
        .padding(.horizontal, 7)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(focused || hoveringInput ? Theme.controlHover : Theme.control))
        .onHover { hoveringInput = $0 }
    }

    private func submitDraft() {
        store.add(draft)
        draft = ""
        // 回车后输入框可能会失去焦点，等这一轮更新完再放回去。
        DispatchQueue.main.async { focused = true }
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
            }
        }
        .onChange(of: editing) { _, isEditing in
            if !isEditing { commitEdit() }
        }
        .contextMenu {
            Button(L("编辑")) { beginEdit(item) }
            Button(L("删除")) {
                // 同步时会直接删掉系统“提醒事项”里的记录，没有撤销，先确认。
                guard !reminders.isActive || AppDelegate.shared.confirm(L("删除这条待办？"), message: L("它也会从系统“提醒事项”里删除。"), action: L("删除")) else { return }
                store.remove(item.id)
            }
            Button(L("清除已完成")) { store.clearDone() }
        }
    }
}
