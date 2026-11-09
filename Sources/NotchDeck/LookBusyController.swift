import AppKit
import Carbon
import IOKit.pwr_mgt
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
        }
    }
}

final class LookBusyController: ObservableObject {
    static let shared = LookBusyController()
    static let randomChoice = "random"
    private static let sceneKey = "lookBusyScene"
    private static let projectKey = "lookBusyProjectPath"

    @Published private(set) var isShowing = false
    @Published private(set) var project: Project
    @Published private(set) var usesCustomProject: Bool
    @Published var sceneChoice: String {
        didSet { UserDefaults.standard.set(sceneChoice, forKey: Self.sceneKey) }
    }

    private var windows: [OverlayWindow] = []
    private var engine: Engine?
    private var timer: Timer?
    private var keyMonitor: Any?
    private var previousApp: NSRunningApplication?
    private var displayAssertion: IOPMAssertionID = 0

    private init() {
        let defaults = UserDefaults.standard
        sceneChoice = defaults.string(forKey: Self.sceneKey) ?? SceneKind.agent.rawValue
        let path = defaults.string(forKey: Self.projectKey)
        project = path.map { Project.scan(URL(fileURLWithPath: $0)) } ?? Project.demo
        usesCustomProject = path != nil
    }

    func toggle() { isShowing ? hide() : show() }

    func start(choice: String) {
        sceneChoice = choice
        show()
    }

    /// 主屏显示选中的场景，其他屏幕各显示一个不同的场景。
    private func scenes(forScreens count: Int) -> [SceneKind] {
        var rest = SceneKind.allCases.shuffled()
        let main = SceneKind(rawValue: sceneChoice) ?? rest[0]
        rest.removeAll { $0 == main }
        return (0..<count).map { $0 == 0 ? main : rest[($0 - 1) % rest.count] }
    }

    func show() {
        guard !isShowing else { return }
        AppDelegate.shared.closePanel()
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front?.processIdentifier == getpid() ? nil : front

        let engine = Engine(project: project, seed: UInt64.random(in: 1...UInt64.max))
        self.engine = engine
        let screens = NSScreen.screens
        let kinds = scenes(forScreens: screens.count)
        for (index, screen) in screens.enumerated() {
            let window = OverlayWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.setFrame(screen.frame, display: false)
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            window.isOpaque = true
            window.backgroundColor = .black
            window.hasShadow = false
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SceneView(engine: engine, kind: kinds[index]))
            window.orderFrontRegardless()
            windows.append(window)
        }
        NSApp.activate(ignoringOtherApps: true)
        windows.first?.makeKey()
        NSCursor.setHiddenUntilMouseMoves(true)

        // 场景显示期间拦截所有按键，打字只会让文字出现得更快；Esc 是随时可用的退出键。
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self, weak engine] event in
            if event.keyCode == UInt16(kVK_Escape) {
                self?.hide()
            } else {
                engine?.keyPressed()
            }
            return nil
        }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak engine] _ in engine?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        keepDisplayOn()
        isShowing = true
    }

    /// 场景放着不动时屏幕也要保持亮着，否则到了系统设定的时间就黑屏了。
    private func keepDisplayOn() {
        guard displayAssertion == 0 else { return }
        let status = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "NotchDeck Look Busy" as CFString,
            &displayAssertion
        )
        if status != kIOReturnSuccess { displayAssertion = 0 }
    }

    private func allowDisplaySleep() {
        guard displayAssertion != 0 else { return }
        IOPMAssertionRelease(displayAssertion)
        displayAssertion = 0
    }

    func hide() {
        guard isShowing else { return }
        allowDisplaySleep()
        timer?.invalidate()
        timer = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
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

struct LookBusyCard: View {
    @ObservedObject private var busy = LookBusyController.shared

    private func chip(_ title: String, _ value: String) -> some View {
        let selected = busy.sceneChoice == value
        return Button { busy.start(choice: value) } label: {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(selected ? Theme.blue : Theme.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 4)
                .frame(maxWidth: .infinity, minHeight: 22)
                .background(Capsule().fill(selected ? Theme.blue.opacity(0.16) : Theme.control))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func chip(_ kind: SceneKind) -> some View { chip(kind.shortTitle, kind.rawValue) }

    var body: some View {
        Card {
            VStack(spacing: 5) {
                HStack(spacing: 5) {
                    Image(systemName: "briefcase.fill").foregroundStyle(Theme.purple)
                    Text(L("装忙")).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("⌃⌥B").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                }
                HStack(spacing: 5) {
                    chip(.agent)
                    chip(.training)
                }
                HStack(spacing: 5) {
                    chip(.paper)
                    chip(.notebook)
                }
                chip(L("随机"), LookBusyController.randomChoice)
            }
        }
    }
}
