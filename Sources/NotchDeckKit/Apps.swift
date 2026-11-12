import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AppEntry: Identifiable, Equatable {
    let path: String
    var id: String { path }
    var name: String { FileManager.default.displayName(atPath: path).replacingOccurrences(of: ".app", with: "") }
    var icon: NSImage { NSWorkspace.shared.icon(forFile: path) }

    func launch() {
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: .init())
    }
}

final class DockStore: ObservableObject {
    static let shared = DockStore()
    static let visibleCount = 9

    private static let defaults = [
        "com.apple.finder", "com.apple.Safari", "com.apple.Notes", "com.apple.iCal", "com.apple.AppStore",
        "com.microsoft.VSCode", "com.apple.Terminal", "com.figma.Desktop", "com.tencent.xinWeChat",
    ]

    @Published private(set) var paths: [String]
    @Published private(set) var allApps: [AppEntry] = []

    private init() {
        if let saved = Storage.load([String].self, from: "dock.json") {
            paths = saved
        } else {
            paths = Self.defaults.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)?.path }
        }
    }

    var items: [AppEntry] {
        paths.filter { FileManager.default.fileExists(atPath: $0) }.map(AppEntry.init(path:))
    }

    func pin(_ path: String) {
        guard !paths.contains(path) else { return }
        paths.append(path)
        persist()
    }

    func unpin(_ path: String) {
        paths.removeAll { $0 == path }
        persist()
    }

    func move(_ path: String, before target: String) {
        guard path != target, let from = paths.firstIndex(of: path), let to = paths.firstIndex(of: target) else { return }
        paths.remove(at: from)
        paths.insert(path, at: to)
        persist()
    }

    func refreshAllApps() {
        DispatchQueue.global(qos: .userInitiated).async {
            let roots = ["/Applications", "/System/Applications", "/System/Applications/Utilities", NSHomeDirectory() + "/Applications"]
            var found = Set<String>()
            let fm = FileManager.default
            for root in roots {
                for name in (try? fm.contentsOfDirectory(atPath: root)) ?? [] {
                    let path = root + "/" + name
                    if name.hasSuffix(".app") {
                        found.insert(path)
                    } else if root == "/Applications", let nested = try? fm.contentsOfDirectory(atPath: path) {
                        nested.filter { $0.hasSuffix(".app") }.forEach { found.insert(path + "/" + $0) }
                    }
                }
            }
            let apps = found.map(AppEntry.init(path:)).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            DispatchQueue.main.async { self.allApps = apps }
        }
    }

    private func persist() { Storage.save(paths, to: "dock.json") }
}

struct DockRow: View {
    @ObservedObject var model: PanelModel
    @ObservedObject private var store = DockStore.shared
    @State private var dragging: String?

    private func collapse() {
        AppDelegate.shared.closePanel()
    }

    private var divider: some View {
        Rectangle().fill(Theme.track).frame(width: 1, height: 30)
    }

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                LookBusyButton()
                KeepAwakeButton()
            }
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

struct AllAppsPage: View {
    @ObservedObject var model: PanelModel
    @ObservedObject private var store = DockStore.shared

    private func collapse() {
        AppDelegate.shared.closePanel()
    }

    var body: some View {
        VStack(spacing: 6) {
            PageHeader(title: L("所有应用"), model: model)
            ScrollView(.vertical) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 11), spacing: 10) {
                    ForEach(store.allApps) { app in
                        VStack(spacing: 3) {
                            AppIcon(app: app, size: 40) { collapse() }
                            Text(app.name).font(.system(size: 10)).lineLimit(1)
                        }
                        .contextMenu {
                            if store.paths.contains(app.path) {
                                Button(L("从快捷栏移除")) { store.unpin(app.path) }
                            } else {
                                Button(L("固定到快捷栏")) { store.pin(app.path) }
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.never)
        }
        .onAppear { store.refreshAllApps() }
    }
}

struct PinnedAppsPage: View {
    @ObservedObject var model: PanelModel
    @ObservedObject private var store = DockStore.shared

    private func collapse() {
        AppDelegate.shared.closePanel()
    }

    var body: some View {
        VStack(spacing: 6) {
            PageHeader(title: L("快捷栏"), model: model) {
                Button {
                    if let url = AppDelegate.shared.pickApplication() { store.pin(url.path) }
                } label: {
                    Label(L("添加 App"), systemImage: "plus").font(.system(size: 12))
                }
                .buttonStyle(.plain)
            }
            ScrollView(.vertical) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 11), spacing: 10) {
                    ForEach(store.items) { app in
                        VStack(spacing: 3) {
                            AppIcon(app: app, size: 40) { collapse() }
                            Text(app.name).font(.system(size: 10)).lineLimit(1)
                        }
                        .contextMenu { Button(L("从快捷栏移除")) { store.unpin(app.path) } }
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.never)
        }
    }
}
