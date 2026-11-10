import AppKit
import SwiftUI

struct SearchResult: Identifiable {
    enum Target {
        case app(AppEntry)
        case todo
        case note
        case clipboard(ClipboardStore.Item)
        case file(URL)
        case web(String)
    }

    let id: String
    let title: String
    let kind: String
    let target: Target

    var icon: NSImage? {
        switch target {
        case .app(let app): return app.icon
        case .file(let url): return NSWorkspace.shared.icon(forFile: url.path)
        default: return nil
        }
    }

    var symbol: String {
        switch target {
        case .todo: return "checkmark.circle"
        case .note: return "note.text"
        case .clipboard: return "doc.on.clipboard"
        case .web: return "globe"
        default: return "doc"
        }
    }
}

final class SearchModel: ObservableObject {
    static let shared = SearchModel()
    private static let maxFiles = 8
    /// 这些目录里基本是缓存和依赖文件，不是用户想找的内容。
    private static let noisyPathParts = ["/Library/", "/.", "/node_modules/", "/IndexedDB/", "/Cache/", "/build/"]

    @Published var query = "" {
        didSet { if query != oldValue { queryChanged() } }
    }
    @Published private(set) var results: [SearchResult] = []
    @Published var selection = 0

    private var spotlight: NSMetadataQuery?
    private var files: [URL] = []
    private var debounce: DispatchWorkItem?

    init() {
        NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: nil, queue: .main) { [weak self] note in
            guard let self, let query = note.object as? NSMetadataQuery, query === self.spotlight else { return }
            self.collectFiles(from: query)
        }
    }

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    func reset() {
        spotlight?.stop()
        spotlight = nil
        debounce?.cancel()
        files = []
        query = ""
        rebuild()
    }

    private func queryChanged() {
        selection = 0
        files = []
        rebuild()
        debounce?.cancel()
        spotlight?.stop()
        spotlight = nil
        guard !trimmed.isEmpty else { return }
        let work = DispatchWorkItem { [weak self] in self?.startSpotlight() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func startSpotlight() {
        let pattern = trimmed.replacingOccurrences(of: "*", with: "").replacingOccurrences(of: "?", with: "")
        guard !pattern.isEmpty else { return }
        let metadata = NSMetadataQuery()
        metadata.searchScopes = [NSMetadataQueryUserHomeScope]
        metadata.predicate = NSPredicate(format: "%K LIKE[cd] %@", NSMetadataItemFSNameKey, "*\(pattern)*")
        metadata.sortDescriptors = [NSSortDescriptor(key: "kMDItemLastUsedDate", ascending: false)]
        spotlight = metadata
        metadata.start()
    }

    private func collectFiles(from metadata: NSMetadataQuery) {
        metadata.stop()
        var found: [URL] = []
        for index in 0..<min(metadata.resultCount, 60) {
            guard let item = metadata.result(at: index) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                  !path.hasSuffix(".app"), !Self.noisyPathParts.contains(where: path.contains) else { continue }
            found.append(URL(fileURLWithPath: path))
            if found.count == Self.maxFiles { break }
        }
        files = found
        rebuild()
    }

    func rebuild() {
        let text = trimmed
        guard !text.isEmpty else {
            results = []
            return
        }
        var output: [SearchResult] = []

        let apps = DockStore.shared.allApps
            // 中文系统里显示名可能是“微信”，同时匹配文件名才能用 WeChat 搜到。
            .filter { $0.name.localizedCaseInsensitiveContains(text) || ($0.path as NSString).lastPathComponent.localizedCaseInsensitiveContains(text) }
            .sorted { first, second in
                let firstPrefix = first.name.lowercased().hasPrefix(text.lowercased())
                let secondPrefix = second.name.lowercased().hasPrefix(text.lowercased())
                return firstPrefix != secondPrefix ? firstPrefix : first.name.count < second.name.count
            }
        output += apps.prefix(6).map { SearchResult(id: "app-\($0.path)", title: $0.name, kind: L("应用"), target: .app($0)) }

        output += TodoStore.shared.items
            .filter { $0.title.localizedCaseInsensitiveContains(text) }
            .prefix(3)
            .map { SearchResult(id: "todo-\($0.id)", title: $0.title, kind: L("待办"), target: .todo) }

        let note = NoteStore.shared.text
        if note.localizedCaseInsensitiveContains(text) {
            let line = note.split(separator: "\n").first { $0.localizedCaseInsensitiveContains(text) }.map(String.init) ?? note
            output.append(SearchResult(id: "note", title: line, kind: L("短记"), target: .note))
        }

        output += ClipboardStore.shared.items
            .filter { $0.preview.localizedCaseInsensitiveContains(text) }
            .prefix(3)
            .map { SearchResult(id: "clip-\($0.id)", title: $0.preview.replacingOccurrences(of: "\n", with: " "), kind: L("剪贴板"), target: .clipboard($0)) }

        output += files.map { SearchResult(id: "file-\($0.path)", title: $0.lastPathComponent, kind: $0.deletingLastPathComponent().lastPathComponent, target: .file($0)) }

        output.append(SearchResult(id: "web", title: L("用网页搜索“%@”", text), kind: L("网页"), target: .web(text)))
        results = output
        selection = min(selection, output.count - 1)
    }

    func moveSelection(by delta: Int) {
        guard !results.isEmpty else { return }
        selection = min(max(selection + delta, 0), results.count - 1)
    }

    func activateSelection(model: PanelModel) {
        guard results.indices.contains(selection) else { return }
        perform(results[selection], model: model)
    }

    /// 翻到这张卡片所在的首页；卡片被隐藏时提示用户。
    private func showCard(_ kind: CardKind, model: PanelModel) {
        model.page = .home
        if let index = CardLayoutStore.shared.visiblePages.firstIndex(where: { $0.contains(kind) }) {
            model.homePage = index
        } else {
            Toasts.shared.show(L("“%@”卡片没有显示在首页", kind.title), icon: "eye.slash")
        }
    }

    func perform(_ result: SearchResult, model: PanelModel) {
        switch result.target {
        case .app(let app):
            app.launch()
        case .todo:
            showCard(.todo, model: model)
            return
        case .note:
            showCard(.note, model: model)
            return
        case .clipboard(let item):
            ClipboardStore.shared.copy(item)
        case .file(let url):
            NSWorkspace.shared.open(url)
        case .web(let text):
            var components = URLComponents(string: "https://www.bing.com/search")
            components?.queryItems = [URLQueryItem(name: "q", value: text)]
            if let url = components?.url { NSWorkspace.shared.open(url) }
        }
        AppDelegate.shared.closePanel()
    }
}

struct SearchPage: View {
    @ObservedObject var model: PanelModel
    @ObservedObject private var search = SearchModel.shared
    @ObservedObject private var dock = DockStore.shared
    @FocusState private var focused: Bool

    private func row(_ result: SearchResult, index: Int) -> some View {
        Button { search.perform(result, model: model) } label: {
            HStack(spacing: 8) {
                Group {
                    if let icon = result.icon {
                        Image(nsImage: icon).resizable()
                    } else {
                        Image(systemName: result.symbol).foregroundStyle(Theme.secondary)
                    }
                }
                .frame(width: 20, height: 20)
                Text(result.title).font(.system(size: 13)).lineLimit(1)
                Spacer(minLength: 8)
                Text(result.kind).font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(1)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(index == search.selection ? Theme.blue.opacity(0.18) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { if $0 { search.selection = index } }
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.secondary)
                TextField(L("搜索应用、文件、待办、短记和剪贴板"), text: $search.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($focused)
                    .onSubmit { search.activateSelection(model: model) }
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Capsule().cardFill())

            Card(padding: 4) {
                if search.results.isEmpty {
                    Text(L("输入关键词开始搜索，方向键选择，回车打开"))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollViewReader { reader in
                        ScrollView(.vertical) {
                            VStack(spacing: 0) {
                                ForEach(Array(search.results.enumerated()), id: \.element.id) { index, result in
                                    row(result, index: index).id(index)
                                }
                            }
                        }
                        .scrollIndicators(.never)
                        .onChange(of: search.selection) { _, value in reader.scrollTo(value) }
                    }
                }
            }
        }
        .onAppear {
            search.reset()
            dock.refreshAllApps()
            focused = true
        }
        .onChange(of: dock.allApps) { _, _ in search.rebuild() }
    }
}
