import AppKit
import ServiceManagement
import SwiftUI

enum Storage {
    static let folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("NotchDeck", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func save<T: Encodable>(_ value: T, to name: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: folder.appendingPathComponent(name), options: .atomic)
    }
}

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

    /// 开启同步时把本地未完成的待办移交给提醒事项，反复开关也不会产生重复项。
    func takeLocalPendingTitles() -> [String] {
        let titles = items.filter { !$0.done }.map(\.title)
        items.removeAll { !$0.done }
        persist()
        return titles
    }

    func showRemoteItems(_ remote: [Item]) { items = remote }

    func useLocalItems() { items = Storage.load([Item].self, from: Self.file) ?? [] }

    private func persist() { Storage.save(items, to: Self.file) }
}

final class NoteStore: ObservableObject {
    static let shared = NoteStore()

    private struct Saved: Codable { var text: String; var color: Int }

    static let palette: [(name: String, color: Color)] = [
        ("青绿", Color(red: 0.76, green: 0.82, blue: 0.66)),
        ("明黄", Color(red: 0.96, green: 0.87, blue: 0.56)),
        ("粉红", Color(red: 0.95, green: 0.75, blue: 0.76)),
        ("天蓝", Color(red: 0.70, green: 0.82, blue: 0.94)),
    ]

    @Published var text: String { didSet { scheduleSave() } }
    @Published var colorIndex: Int { didSet { scheduleSave() } }
    private var pendingSave: DispatchWorkItem?

    private init() {
        let saved = Storage.load(Saved.self, from: "note.json")
        text = saved?.text ?? ""
        colorIndex = saved?.color ?? 0
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Storage.save(Saved(text: self.text, color: self.colorIndex), to: "note.json")
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }
}

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

final class Toasts: ObservableObject {
    static let shared = Toasts()
    struct Toast: Equatable { let text: String; let icon: String }

    @Published private(set) var current: Toast?
    private var clearWork: DispatchWorkItem?

    func show(_ text: String, icon: String) {
        clearWork?.cancel()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { current = Toast(text: text, icon: icon) }
        let work = DispatchWorkItem { [weak self] in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { self?.current = nil }
        }
        clearWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }
}

final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard

    @Published var overheatThreshold: Double {
        didSet { defaults.set(overheatThreshold, forKey: "overheatThreshold") }
    }
    @Published var showMenuBarTemperature: Bool {
        didSet { defaults.set(showMenuBarTemperature, forKey: "showMenuBarTemperature") }
    }
    @Published var launchError: String?

    private init() {
        overheatThreshold = defaults.object(forKey: "overheatThreshold") as? Double ?? 90
        showMenuBarTemperature = defaults.object(forKey: "showMenuBarTemperature") as? Bool ?? true
    }

    var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    func setLaunchAtLogin(_ enabled: Bool) {
        objectWillChange.send()
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchError = nil
        } catch {
            launchError = L("设置失败：%@", error.localizedDescription)
        }
    }
}

final class FocusTimer: ObservableObject {
    static let shared = FocusTimer()
    static let minutes = 25

    @Published private(set) var remaining: Int?
    private var end: Date?
    private var timer: Timer?

    var running: Bool { remaining != nil }
    var label: String { Self.format(remaining ?? 0) }

    static func format(_ seconds: Int) -> String {
        String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    func toggle() {
        running ? finish(completed: false) : start()
    }

    private func start() {
        end = Date().addingTimeInterval(TimeInterval(Self.minutes * 60))
        remaining = Self.minutes * 60
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.update() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        Self.runShortcut("NotchDeck 专注开始")
    }

    private func update() {
        guard let end else { return }
        let left = Int(end.timeIntervalSinceNow.rounded(.up))
        if left <= 0 { finish(completed: true) } else { remaining = left }
    }

    private func finish(completed: Bool) {
        timer?.invalidate()
        timer = nil
        end = nil
        remaining = nil
        Self.runShortcut("NotchDeck 专注结束")
        if completed {
            NSSound(named: "Glass")?.play()
            Toasts.shared.show(L("专注结束"), icon: "checkmark.circle")
        }
    }

    /// 系统没有开放勿扰接口；如果用户建了同名“快捷指令”，就由它来开关勿扰。
    private static func runShortcut(_ name: String) {
        DispatchQueue.global(qos: .utility).async {
            let list = Process()
            let pipe = Pipe()
            list.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            list.arguments = ["list"]
            list.standardOutput = pipe
            list.standardError = FileHandle.nullDevice
            guard (try? list.run()) != nil else { return }
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            list.waitUntilExit()
            guard output.split(separator: "\n").contains(Substring(name)) else { return }
            let run = Process()
            run.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            run.arguments = ["run", name]
            try? run.run()
        }
    }
}
