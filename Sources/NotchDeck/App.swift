import AppKit
import Carbon
import Combine

@main
enum Entry {
    static func main() {
        Storage.migrateLegacySettings()
        let app = NSApplication.shared
        app.delegate = AppDelegate.shared
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static let shared = AppDelegate()

    private(set) lazy var controller = PanelController()
    private var statusItem: NSStatusItem!
    private var statusSubscription: AnyCancellable?
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
        ReminderSync.shared.restore()
        AgendaStore.shared.refresh()
        UpdateChecker.shared.start()
        setUpStatusItem()
        refreshMonitorMode()

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.closePanel()
        }
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, !self.modalOpen else { return }
            self.closePanel()
        }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.controller.model.expanded, !self.isComposingText else { return event }
            let onSearch = self.controller.model.page == .search
            switch event.keyCode {
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

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "NotchDeck"
        guard let button = statusItem.button else { return }
        let symbol = NSImage(systemSymbolName: "rectangle.topthird.inset.filled", accessibilityDescription: "NotchDeck")
        let image = symbol?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .medium))
        image?.isTemplate = true
        button.image = image
        button.imagePosition = .imageOnly
        button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        button.target = self
        button.action = #selector(statusItemClicked)

        // @Published 在值改变前发出通知，切到下一轮主循环才能读到新值。
        statusSubscription = Publishers.MergeMany([
            Toasts.shared.$current.map { _ in () }.eraseToAnyPublisher(),
            FocusTimer.shared.$remaining.map { _ in () }.eraseToAnyPublisher(),
            CountdownTimer.shared.$remaining.map { _ in () }.eraseToAnyPublisher(),
            SystemMonitor.shared.$cpuTemp.map { _ in () }.eraseToAnyPublisher(),
            SystemMonitor.shared.$cpu.map { _ in () }.eraseToAnyPublisher(),
            SystemMonitor.shared.$downloadSpeed.map { _ in () }.eraseToAnyPublisher(),
            SystemMonitor.shared.$batteryPercent.map { _ in () }.eraseToAnyPublisher(),
            SystemMonitor.shared.$isCharging.map { _ in () }.eraseToAnyPublisher(),
            AppSettings.shared.$showMenuBarTemperature.map { _ in () }.eraseToAnyPublisher(),
            AppSettings.shared.$showMenuBarCPU.map { _ in () }.eraseToAnyPublisher(),
            AppSettings.shared.$showMenuBarNetwork.map { _ in () }.eraseToAnyPublisher(),
            AppSettings.shared.$showMenuBarBattery.map { _ in () }.eraseToAnyPublisher(),
            UpdateChecker.shared.$latestVersion.map { _ in () }.eraseToAnyPublisher(),
        ])
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in self?.refreshStatusText() }
    }

    /// 平时显示温度和倒计时；面板收起时的提醒会临时占用这个位置，面板打开时提醒已显示在面板内。
    private func refreshStatusText() {
        guard let button = statusItem.button else { return }
        var text: String
        if let toast = Toasts.shared.current, !controller.model.expanded {
            text = toast.text
        } else {
            let timer = (FocusTimer.shared.remaining ?? CountdownTimer.shared.remaining).map(FocusTimer.format)
            // 用粗箭头表示有更新，避免和网速的上传箭头混淆。
            let update = UpdateChecker.shared.latestVersion == nil ? nil : "⬆︎"
            text = (monitorStatusParts + [timer, update].compactMap { $0 }).joined(separator: "  ")
        }
        if !text.isEmpty { text = " \(text)" }
        guard button.title != text else { return }
        button.title = text
        button.imagePosition = text.isEmpty ? .imageOnly : .imageLeading
    }

    private var monitorStatusParts: [String] {
        let settings = AppSettings.shared
        let monitor = SystemMonitor.shared
        var parts: [String] = []
        if settings.showMenuBarTemperature, let temperature = formatTemperature(monitor.cpuTemp) { parts.append(temperature) }
        if settings.showMenuBarCPU { parts.append("CPU \(Int((monitor.cpu * 100).rounded()))%") }
        if settings.showMenuBarNetwork {
            parts.append("↓\(formatCompactSpeed(monitor.downloadSpeed)) ↑\(formatCompactSpeed(monitor.uploadSpeed))")
        }
        if settings.showMenuBarBattery, let percent = monitor.batteryPercent {
            parts.append((monitor.isCharging ? "⚡︎" : "") + "\(percent)%")
        }
        return parts
    }

    @objc private func statusItemClicked() {
        if controller.model.expanded {
            closePanel()
            return
        }
        let mouse = NSEvent.mouseLocation
        guard let screen = screen(containing: mouse) else { return }
        // 多显示器时状态栏窗口的 frame 可能属于另一块屏幕，这时以鼠标位置为准。
        var midX = mouse.x
        if let frame = statusItem.button?.window?.frame, frame.minX...frame.maxX ~= mouse.x {
            midX = frame.midX
        }
        openPanel(midX: midX, on: screen)
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
    private func togglePageFromHotKey(_ page: Page) {
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
        if let frame = statusItem.button?.window?.frame, screen.frame.contains(frame.origin) {
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

    private func screen(containing point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func openPanel(midX: CGFloat, on screen: NSScreen) {
        controller.open(midX: midX, on: screen)
        refreshMonitorMode()
        syncButtonHighlight()
    }

    func closePanel() {
        guard controller.model.expanded else { return }
        controller.close()
        refreshMonitorMode()
        syncButtonHighlight()
    }

    /// 鼠标抬起时系统会重置按钮高亮，所以放到下一轮再设置。
    private func syncButtonHighlight() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.statusItem.button?.highlight(self.controller.model.expanded)
        }
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
            self?.togglePageFromHotKey(.clipboard)
        }
        if !taken.isEmpty {
            Toasts.shared.show(L("%@ 已被占用", taken.joined(separator: " ")), icon: "exclamationmark.triangle")
        }
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
