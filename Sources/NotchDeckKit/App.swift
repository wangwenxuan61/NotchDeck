import AppKit
import Carbon

/// App 的入口。代码都在 NotchDeckKit 库里，启动程序只调用这一个函数，这样检查程序也能直接引用库里的逻辑。
public func runNotchDeck() -> Never {
    Storage.migrateLegacySettings()
    let app = NSApplication.shared
    app.delegate = AppDelegate.shared
    app.setActivationPolicy(.accessory)
    app.run()
    exit(0)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static let shared = AppDelegate()

    private(set) lazy var controller = PanelController()
    private var statusBar: StatusItemController!
    private var panelHotKey: HotKey?
    private var busyHotKey: HotKey?
    private var clipboardHotKey: HotKey?
    private var swipeDistance: CGFloat = 0
    private var swipeConsumed = false
    var modalOpen = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        SystemMonitor.shared.start()
        MediaController.shared.start()
        ClipboardStore.shared.start()
        KeepAwake.shared.restoreAfterRestart()
        ReminderSync.shared.restore()
        AgendaStore.shared.refresh()
        TokenUsageStore.shared.refreshIfNeeded()
        UpdateChecker.shared.start()
        statusBar = StatusItemController(app: self)
        refreshMonitorMode()

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.closePanel()
        }
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, !self.modalOpen else { return }
            self.closePanel()
        }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // 确认框和文件选择框打开时，Esc 要留给它们自己。
            guard let self, self.controller.model.expanded, !self.isComposingText, !self.modalOpen else { return event }
            let onSearch = self.controller.model.page == .search
            switch event.keyCode {
            case 53 where !onSearch && NSApp.keyWindow?.firstResponder is NSTextView:
                // 正在待办或短记里输入时，Esc 先结束输入，再按一次才关面板。
                NSApp.keyWindow?.makeFirstResponder(nil)
            case 53:
                self.closePanel()
            case 125 where onSearch:
                SearchModel.shared.moveSelection(by: 1)
            case 126 where onSearch:
                SearchModel.shared.moveSelection(by: -1)
            default:
                return event
            }
            return nil
        }
        NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.handleSwipe(event)
            return event
        }
        registerHotKeys()
        applyDebugArguments()
    }

    func applicationWillTerminate(_ notification: Notification) {
        MediaController.shared.stop()
        ClipboardStore.shared.persistNow()
    }

    func toggleFromHotKey() {
        guard !LookBusyController.shared.isShowing else { return }
        if controller.model.expanded {
            closePanel()
            return
        }
        openPanelFromKeyboard()
    }

    /// 已经停在这一页时收起面板，否则打开或切换到这一页。
    func togglePage(_ page: Page) {
        guard !LookBusyController.shared.isShowing else { return }
        if controller.model.expanded {
            if controller.model.page == page {
                closePanel()
            } else {
                controller.model.page = page
            }
            return
        }
        openPanelFromKeyboard()
        controller.model.page = page
    }

    private func openPanelFromKeyboard() {
        guard let screen = screen(containing: NSEvent.mouseLocation) else { return }
        var midX = screen.frame.midX
        if let frame = statusBar.buttonFrame, screen.frame.contains(frame.origin) {
            midX = frame.midX
        }
        openPanel(midX: midX, on: screen)
    }

    /// 输入法正在选词时，Esc 和方向键要留给输入法。
    private var isComposingText: Bool {
        (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() ?? false
    }

    /// 触控板左右滑动翻页，一次手势只翻一页。
    private func handleSwipe(_ event: NSEvent) {
        if event.phase == .began {
            swipeDistance = 0
            swipeConsumed = false
        }
        guard event.phase == .changed, controller.model.expanded, controller.model.page == .home, !swipeConsumed else { return }
        guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else { return }
        swipeDistance += event.scrollingDeltaX
        if abs(swipeDistance) > 60 {
            swipeConsumed = true
            controller.model.turnHomePage(by: swipeDistance < 0 ? 1 : -1)
        }
    }

    func screen(containing point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens.first
    }

    func openPanel(midX: CGFloat, on screen: NSScreen) {
        controller.open(midX: midX, on: screen)
        // 用户可能刚在系统设置里授权了日历，这种情况系统不会通知 App。
        AgendaStore.shared.refresh()
        TokenUsageStore.shared.refreshIfNeeded()
        UpdateChecker.shared.showUpdateNoticeIfNeeded()
        refreshMonitorMode()
        statusBar.syncHighlight()
    }

    func closePanel() {
        guard controller.model.expanded else { return }
        controller.close()
        refreshMonitorMode()
        statusBar.syncHighlight()
    }

    func refreshMonitorMode() {
        let model = controller.model
        SystemMonitor.shared.setMode(model.expanded ? (model.page == .monitor ? .detail : .expanded) : .collapsed)
    }

    /// 调试用：`--open [--page=<页面>] [--snapshot=<路径>]` 打开面板并把界面导出为 PNG。
    private func applyDebugArguments() {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("--open") else { return }
        // 状态栏图标的窗口位置在启动后才确定，所以延迟打开。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.toggleFromHotKey() }
        if let raw = args.first(where: { $0.hasPrefix("--page=") })?.dropFirst(7), let page = Page(rawValue: String(raw)) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.controller.model.page = page }
        }
        if let path = args.first(where: { $0.hasPrefix("--snapshot=") })?.dropFirst(11) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                self.controller.snapshot(to: String(path))
                NSApp.terminate(nil)
            }
        }
    }

    private func registerHotKeys() {
        var taken: [String] = []
        func register(_ label: String, _ keyCode: Int, _ modifiers: Int, id: UInt32, action: @escaping () -> Void) -> HotKey? {
            let hotKey = HotKey(keyCode: UInt32(keyCode), modifiers: UInt32(modifiers), id: id, action: action)
            if hotKey == nil || HotKey.isUsedBySystem(keyCode: UInt32(keyCode), modifiers: UInt32(modifiers)) {
                taken.append(label)
            }
            return hotKey
        }
        panelHotKey = register("⌥⌘N", kVK_ANSI_N, cmdKey | optionKey, id: 1) { [weak self] in
            self?.toggleFromHotKey()
        }
        busyHotKey = register("⌃⌥B", kVK_ANSI_B, controlKey | optionKey, id: 2) {
            LookBusyController.shared.toggle()
        }
        // 不用 ⌥⌘V：那是 Finder 移动文件的快捷键。
        clipboardHotKey = register("⌃⌥V", kVK_ANSI_V, controlKey | optionKey, id: 3) { [weak self] in
            self?.togglePage(.clipboard)
        }
        if !taken.isEmpty {
            Toasts.shared.show(L("%@ 已被占用", taken.joined(separator: " ")), icon: "exclamationmark.triangle")
        }
    }

    /// 不能撤销的操作先确认。和选文件一样临时切到前台，避免面板被自动收起。
    func confirm(_ title: String, message: String, action: String) -> Bool {
        modalOpen = true
        defer { modalOpen = false }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: action).hasDestructiveAction = true
        alert.addButton(withTitle: L("取消")).keyEquivalent = "\u{1b}"
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    func pickFolder() -> URL? {
        modalOpen = true
        defer { modalOpen = false }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = L("只读取文件和文件夹的名称，不会打开文件内容。")
        panel.prompt = L("使用这个文件夹")
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// 打开系统文件选择框时临时切到前台，避免面板被自动收起。
    func pickApplication() -> URL? {
        modalOpen = true
        defer { modalOpen = false }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = L("添加")
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.url : nil
    }
}
