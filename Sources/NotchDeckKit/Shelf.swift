import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 文件暂存架：拖进来先放着，要用的时候再拖出去。只记文件的路径，不复制文件，被删掉或移走的文件自动去掉。
final class ShelfStore: ObservableObject {
    static let shared = ShelfStore()
    static let limit = 12
    private static let file = "shelf.json"

    /// 最近放进来的在前面。
    @Published private(set) var paths: [String]

    private init() {
        paths = (Storage.load([String].self, from: Self.file) ?? []).filter { FileManager.default.fileExists(atPath: $0) }
    }

    func add(_ urls: [URL]) {
        let added = urls.filter(\.isFileURL).map { $0.standardizedFileURL.path }
        guard !added.isEmpty else { return }
        var next = paths.filter { !added.contains($0) }
        next.insert(contentsOf: added, at: 0)
        paths = Array(next.prefix(Self.limit))
        persist()
    }

    func remove(_ path: String) {
        paths.removeAll { $0 == path }
        persist()
    }

    func clear() {
        paths = []
        persist()
    }

    /// 打开面板时检查一下，文件在别处被删掉或移走了就不再显示。
    func pruneMissing() {
        let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
        guard existing != paths else { return }
        paths = existing
        persist()
    }

    private func persist() { Storage.save(paths, to: Self.file) }

    /// 从拖进来的内容里取出文件地址。
    static func load(_ providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
        let group = DispatchGroup()
        var urls: [URL] = []
        let lock = NSLock()
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL {
                    lock.lock()
                    urls.append(url)
                    lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { completion(urls) }
    }
}

struct ShelfCard: View {
    @ObservedObject private var store = ShelfStore.shared
    @State private var targeted = false
    private static let visible = 3

    private func item(_ path: String) -> some View {
        let url = URL(fileURLWithPath: path)
        return Button {
            AppDelegate.shared.closePanel()
            NSWorkspace.shared.open(url)
        } label: {
            VStack(spacing: 3) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                    .resizable()
                    .frame(width: 30, height: 30)
                Text(url.lastPathComponent)
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(path)
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        .contextMenu {
            Button(L("在访达中显示")) {
                AppDelegate.shared.closePanel()
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            Button(L("从暂存架移除")) { store.remove(path) }
        }
    }

    private var emptyHint: some View {
        VStack(spacing: 4) {
            Image(systemName: "arrow.down.doc").font(.system(size: 16)).foregroundStyle(Theme.tertiary)
            Text(L("把文件拖到这里暂放，用时再拖出去"))
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .minimumScaleFactor(0.85)
        }
        .padding(6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Theme.tertiary.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                CardHeader(L("暂存架"), symbol: "tray.full", color: Theme.orange) {
                    if !store.paths.isEmpty {
                        Button { store.clear() } label: {
                            Image(systemName: "xmark.circle").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(L("清空暂存架"))
                    }
                }
                if store.paths.isEmpty {
                    emptyHint
                } else {
                    HStack(alignment: .top, spacing: 4) {
                        ForEach(store.paths.prefix(Self.visible), id: \.self) { item($0) }
                    }
                    Spacer(minLength: 0)
                    if store.paths.count > Self.visible {
                        Text(L("还有 %d 个", store.paths.count - Self.visible))
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.secondary)
                    }
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Theme.orange, lineWidth: targeted ? 2 : 0)
        )
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            ShelfStore.load(providers) { store.add($0) }
            return true
        }
        .onAppear { store.pruneMissing() }
    }
}
