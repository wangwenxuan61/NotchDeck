import AppKit
import Carbon
import SwiftUI

/// 盖住整块屏幕的无边框窗口，层级高于菜单栏和 Dock。
final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

extension SceneKind {
    var shortTitle: String {
        switch self {
        case .agent: return L("AI 写代码")
        case .training: return L("训练")
        case .paper: return L("写论文")
        case .notebook: return L("数据分析")
        case .dashboard: return L("监控大屏")
        case .build: return L("编译和测试")
        case .ops: return L("服务器运维")
        case .spreadsheet: return L("做表格")
        case .matlab: return L("MATLAB 仿真")
        case .reading: return L("读文献")
        }
    }
}

/// 一块要盖住的屏幕。用屏幕名称区分，型号相同的屏幕按顺序加编号。
struct BusyScreen: Identifiable, Equatable {
    let id: String
    let name: String
    let isMain: Bool
    let isBuiltIn: Bool
    let portrait: Bool

    static func current() -> [(screen: NSScreen, info: BusyScreen)] {
        var seen: [String: Int] = [:]
        return NSScreen.screens.enumerated().map { index, screen in
            let name = screen.localizedName
            seen[name, default: 0] += 1
            let id = seen[name]! > 1 ? "\(name) (\(seen[name]!))" : name
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            let info = BusyScreen(id: id, name: id, isMain: index == 0,
                                  isBuiltIn: number.map { CGDisplayIsBuiltin($0) != 0 } ?? false,
                                  portrait: screen.frame.height > screen.frame.width)
            return (screen, info)
        }
    }
}

final class LookBusyController: ObservableObject {
    static let shared = LookBusyController()
    static let randomChoice = "random"
    private static let sceneKey = "lookBusyScene"
    private static let screenScenesKey = "lookBusyScreenScenes"
    private static let mainOnlyKey = "lookBusyMainOnly"
    private static let projectKey = "lookBusyProjectPath"

    @Published private(set) var isShowing = false
    @Published private(set) var project: Project
    @Published private(set) var usesCustomProject: Bool
    /// 主屏幕的场景。
    @Published var sceneChoice: String {
        didSet { UserDefaults.standard.set(sceneChoice, forKey: Self.sceneKey) }
    }
    /// 其他屏幕的场景，按屏幕名称记住；没选过的屏幕随机。
    @Published private(set) var screenChoices: [String: String] {
        didSet { UserDefaults.standard.set(screenChoices, forKey: Self.screenScenesKey) }
    }
    @Published var mainOnly: Bool {
        didSet { UserDefaults.standard.set(mainOnly, forKey: Self.mainOnlyKey) }
    }

    private var windows: [OverlayWindow] = []
    /// 这次装忙里每块屏幕实际显示的场景。中途接上或拔掉显示器重建窗口时，已有屏幕的场景不变。
    private var assigned: [String: SceneKind] = [:]
    private var engine: Engine?
    private var timer: Timer?
    private var keyMonitor: Any?
    private var screenObserver: NSObjectProtocol?
    private var previousApp: NSRunningApplication?
    /// 场景放着不动时屏幕也要保持亮着，否则到了系统设定的时间就黑屏了。
    private let displayLock = DisplayWakeLock(name: "NotchDeck Look Busy")

    private init() {
        let defaults = UserDefaults.standard
        sceneChoice = defaults.string(forKey: Self.sceneKey) ?? SceneKind.agent.rawValue
        screenChoices = defaults.dictionary(forKey: Self.screenScenesKey) as? [String: String] ?? [:]
        mainOnly = defaults.bool(forKey: Self.mainOnlyKey)
        let path = defaults.string(forKey: Self.projectKey)
        project = path.map { Project.scan(URL(fileURLWithPath: $0)) } ?? Project.demo
        usesCustomProject = path != nil
    }

    func toggle() { isShowing ? hide() : show() }

    func start(choice: String) {
        sceneChoice = choice
        show()
    }

    func choice(for screen: BusyScreen) -> String {
        screen.isMain ? sceneChoice : screenChoices[screen.id] ?? Self.randomChoice
    }

    func setChoice(_ choice: String, for screen: BusyScreen) {
        if screen.isMain { sceneChoice = choice } else { screenChoices[screen.id] = choice }
    }

    /// 给每块屏幕定场景：选了的照用，随机的避开别的屏幕已经在用的场景，竖屏优先选竖着也排得开的场景。
    static func assign(_ screens: [BusyScreen], choices: (BusyScreen) -> String, keeping kept: [String: SceneKind] = [:],
                       rng: inout SplitMix64) -> [String: SceneKind] {
        var result = kept.filter { id, _ in screens.contains { $0.id == id } }
        for screen in screens where result[screen.id] == nil {
            if let kind = SceneKind(rawValue: choices(screen)) {
                result[screen.id] = kind
            }
        }
        for screen in screens where result[screen.id] == nil {
            let used = Set(result.values)
            let fitting = SceneKind.allCases.filter { !screen.portrait || $0.suitsPortrait }
            let pool = [fitting.filter { !used.contains($0) }, SceneKind.allCases.filter { !used.contains($0) }, fitting]
                .first { !$0.isEmpty } ?? SceneKind.allCases
            result[screen.id] = rng.pick(pool)
        }
        return result
    }

    func show() {
        guard !isShowing else { return }
        AppDelegate.shared.closePanel()
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front?.processIdentifier == getpid() ? nil : front
        let seed = UInt64.random(in: 1...UInt64.max)
        assigned = [:]
        engine = Engine(project: project, seed: seed, kinds: [])
        isShowing = true
        layoutWindows()
        NSApp.activate(ignoringOtherApps: true)
        windows.first?.makeKey()
        NSCursor.setHiddenUntilMouseMoves(true)

        // 场景显示期间拦截所有按键，打字只会让文字出现得更快；Esc 是随时可用的退出键。
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if event.keyCode == UInt16(kVK_Escape) {
                self?.hide()
            } else {
                self?.engine?.keyPressed()
            }
            return nil
        }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            self?.layoutWindows()
            self?.windows.first?.makeKey()
        }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.engine?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        displayLock.acquire()
    }

    /// 按现在接着的屏幕重建窗口。插拔显示器、改分辨率或旋转屏幕后都会再调用一次。
    private func layoutWindows() {
        guard isShowing, let engine else { return }
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        var screens = BusyScreen.current()
        if mainOnly { screens = Array(screens.prefix(1)) }
        var rng = SplitMix64(state: UInt64.random(in: 1...UInt64.max))
        assigned = Self.assign(screens.map(\.info), choices: choice(for:), keeping: assigned, rng: &rng)
        engine.add(Set(assigned.values))
        for (screen, info) in screens {
            guard let kind = assigned[info.id] else { continue }
            let window = OverlayWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.setFrame(screen.frame, display: false)
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            window.isOpaque = true
            window.backgroundColor = .black
            window.hasShadow = false
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SceneView(engine: engine, kind: kind))
            window.orderFrontRegardless()
            windows.append(window)
        }
    }

    func hide() {
        guard isShowing else { return }
        displayLock.release()
        timer?.invalidate()
        timer = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        assigned = [:]
        engine = nil
        isShowing = false
        // 不能用 NSApp.hide：整个 App 被隐藏后，菜单栏面板就打不开了。
        if let previousApp {
            previousApp.activate(options: [])
        } else {
            NSApp.deactivate()
        }
        previousApp = nil
    }

    func chooseProject() {
        AppDelegate.shared.closePanel()
        guard let url = AppDelegate.shared.pickFolder() else { return }
        project = Project.scan(url)
        usesCustomProject = true
        UserDefaults.standard.set(url.path, forKey: Self.projectKey)
    }

    func useDemoProject() {
        project = Project.demo
        usesCustomProject = false
        UserDefaults.standard.removeObject(forKey: Self.projectKey)
    }
}

/// 首页的装忙卡片：显示当前场景，点开始或换场景。
struct LookBusyCard: View {
    @ObservedObject private var busy = LookBusyController.shared
    @State private var choosing = false

    var body: some View {
        Card {
            VStack(spacing: 8) {
                CardHeader(L("装忙"), symbol: "briefcase.fill", color: Theme.purple) {
                    Text("⌃⌥B").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                }
                Spacer(minLength: 0)
                Button { busy.show() } label: {
                    Text(SceneKind(rawValue: busy.sceneChoice)?.shortTitle ?? L("随机"))
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity, minHeight: 30)
                        .capsuleFill(Theme.purple.opacity(0.16))
                }
                .buttonStyle(.plain)
                .help(L("全屏装忙（⌃⌥B）"))
                Button { choosing.toggle() } label: {
                    Label(L("换一个装忙场景"), systemImage: "chevron.down")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $choosing, arrowEdge: .bottom) {
                    LookBusyChooser { choosing = false }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

/// 底部的装忙按钮：点左边用当前场景开始，点箭头换场景。
struct LookBusyButton: View {
    @ObservedObject private var busy = LookBusyController.shared
    @State private var choosing = false

    private var sceneTitle: String { SceneKind(rawValue: busy.sceneChoice)?.shortTitle ?? L("随机") }

    var body: some View {
        HStack(spacing: 0) {
            Button { busy.show() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "briefcase.fill").foregroundStyle(Theme.purple)
                    Text(L("装忙")).font(.system(size: 13, weight: .medium))
                    Text(sceneTitle).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
                .lineLimit(1)
                .fixedSize()
                .padding(.leading, 14)
                .padding(.trailing, 4)
                .frame(height: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("全屏装忙（⌃⌥B）"))
            Button { choosing.toggle() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
                    .padding(.leading, 4)
                    .padding(.trailing, 12)
                    .frame(height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("换一个装忙场景"))
            .popover(isPresented: $choosing, arrowEdge: .bottom) {
                LookBusyChooser { choosing = false }
            }
        }
        .capsuleFill(Theme.control)
    }
}

/// 选场景。只有一块屏幕时点一下就开始；接了多块屏幕时每块屏幕分别选，再点开始。
struct LookBusyChooser: View {
    @ObservedObject private var busy = LookBusyController.shared
    let dismiss: () -> Void
    private let screens = BusyScreen.current().map(\.info)

    private func row(_ title: String, _ value: String) -> some View {
        Button {
            dismiss()
            busy.start(choice: value)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.blue)
                    .opacity(busy.sceneChoice == value ? 1 : 0)
                Text(title).font(.system(size: 13))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var singleScreen: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SceneKind.allCases, id: \.self) { row($0.shortTitle, $0.rawValue) }
            Divider().padding(.vertical, 2)
            row(L("随机"), LookBusyController.randomChoice)
        }
        .padding(6)
        .frame(width: 190)
    }

    private func screenRow(_ screen: BusyScreen) -> some View {
        let symbol = screen.isBuiltIn ? "laptopcomputer" : screen.portrait ? "rectangle.portrait" : "display"
        let disabled = busy.mainOnly && !screen.isMain
        return HStack(spacing: 8) {
            Image(systemName: symbol).frame(width: 18).foregroundStyle(Theme.secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text(screen.name).font(.system(size: 12)).lineLimit(1)
                if screen.isMain {
                    Text(L("主屏幕")).font(.system(size: 10)).foregroundStyle(Theme.secondary)
                }
            }
            Spacer(minLength: 8)
            Picker("", selection: Binding(get: { busy.choice(for: screen) }, set: { busy.setChoice($0, for: screen) })) {
                Text(L("随机")).tag(LookBusyController.randomChoice)
                Divider()
                ForEach(SceneKind.allCases, id: \.self) { Text($0.shortTitle).tag($0.rawValue) }
            }
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
        }
        .opacity(disabled ? 0.4 : 1)
        .disabled(disabled)
        .frame(height: 30)
    }

    private var multiScreen: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(screens) { screenRow($0) }
            Divider().padding(.vertical, 2)
            Toggle(L("只盖住主屏幕，其他屏幕不动"), isOn: $busy.mainOnly)
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
            HStack {
                Text(L("随机时竖屏优先用竖着排得开的场景"))
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Button(L("开始装忙")) {
                    dismiss()
                    busy.show()
                }
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(10)
        .frame(width: 330)
    }

    var body: some View {
        if screens.count > 1 { multiScreen } else { singleScreen }
    }
}
