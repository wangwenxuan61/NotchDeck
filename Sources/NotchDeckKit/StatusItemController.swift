import AppKit
import Combine
import CoreAudio

/// 菜单栏图标：左键开关面板，右键弹出快捷菜单，图标旁显示温度、计时等状态。
final class StatusItemController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var subscription: AnyCancellable?
    private unowned let app: AppDelegate

    init(app: AppDelegate) {
        self.app = app
        super.init()
        statusItem.autosaveName = "NotchDeck"
        if let button = statusItem.button {
            let symbol = NSImage(systemSymbolName: "rectangle.topthird.inset.filled", accessibilityDescription: "NotchDeck")
            let image = symbol?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .medium))
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageOnly
            button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // @Published 在值改变前发出通知，切到下一轮主循环才能读到新值。
        func changes<Value>(_ publisher: Published<Value>.Publisher) -> AnyPublisher<Void, Never> {
            publisher.map { _ in () }.eraseToAnyPublisher()
        }
        subscription = Publishers.MergeMany([
            changes(Toasts.shared.$current),
            changes(FocusTimer.shared.$remaining),
            changes(CountdownTimer.shared.$remaining),
            changes(SystemMonitor.shared.$cpuTemp),
            changes(SystemMonitor.shared.$cpu),
            changes(SystemMonitor.shared.$downloadSpeed),
            changes(SystemMonitor.shared.$batteryPercent),
            changes(SystemMonitor.shared.$isCharging),
            changes(AppSettings.shared.$showMenuBarTemperature),
            changes(AppSettings.shared.$showMenuBarCPU),
            changes(AppSettings.shared.$showMenuBarNetwork),
            changes(AppSettings.shared.$showMenuBarBattery),
            changes(AppSettings.shared.$showMenuBarUpdate),
            changes(UpdateChecker.shared.$latestVersion),
            changes(KeepAwake.shared.$isOn),
            changes(KeepAwake.shared.$minutesLeft),
        ])
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in self?.refreshText() }
    }

    /// 图标所在窗口的位置，用快捷键打开面板时让面板对齐图标。
    var buttonFrame: NSRect? { statusItem.button?.window?.frame }

    /// 鼠标抬起时系统会重置按钮高亮，所以放到下一轮再设置。
    func syncHighlight() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.statusItem.button?.highlight(self.app.controller.model.expanded)
        }
    }

    // MARK: - 图标旁的文字

    /// 平时显示温度和倒计时；面板收起时的提醒会临时占用这个位置，面板打开时提醒已显示在面板内。
    private func refreshText() {
        guard let button = statusItem.button else { return }
        var text: String
        if let toast = Toasts.shared.current, !app.controller.model.expanded {
            text = toast.text
        } else {
            let timer = (FocusTimer.shared.remaining ?? CountdownTimer.shared.remaining).map(FocusTimer.format)
            // 用粗箭头表示有更新，避免和网速的上传箭头混淆。
            let update = UpdateChecker.shared.latestVersion == nil || !AppSettings.shared.showMenuBarUpdate ? nil : "⬆︎"
            text = ([keepAwakeText].compactMap { $0 } + monitorParts + [timer, update].compactMap { $0 }).joined(separator: "  ")
        }
        if !text.isEmpty { text = " \(text)" }
        guard button.title != text else { return }
        button.title = text
        button.imagePosition = text.isEmpty ? .imageOnly : .imageLeading
    }

    /// 防止休眠开着时放一个杯子，定时的话再加上剩余时间，免得忘了关、一直耗电。
    private var keepAwakeText: String? {
        let keepAwake = KeepAwake.shared
        guard keepAwake.isOn else { return nil }
        return keepAwake.minutesLeft.map { "☕︎ " + formatCompactDuration(minutes: $0) } ?? "☕︎"
    }

    private var monitorParts: [String] {
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

    // MARK: - 点击

    @objc private func clicked() {
        if let event = NSApp.currentEvent, event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showMenu()
            return
        }
        if app.controller.model.expanded {
            app.closePanel()
            return
        }
        let mouse = NSEvent.mouseLocation
        guard let screen = app.screen(containing: mouse) else { return }
        // 多显示器时状态栏窗口的 frame 可能属于另一块屏幕，这时以鼠标位置为准。
        var midX = mouse.x
        if let frame = buttonFrame, frame.minX...frame.maxX ~= mouse.x {
            midX = frame.midX
        }
        app.openPanel(midX: midX, on: screen)
    }

    // MARK: - 右键菜单

    private func showMenu() {
        app.closePanel()
        let updates = UpdateChecker.shared
        let updateItem = updates.latestVersion.map { menuItem(L("更新到 %@", $0), #selector(updateNow), enabled: updates.phase != .downloading) }
            ?? menuItem(updates.isChecking ? L("检查中…") : L("检查更新"), #selector(checkForUpdates), enabled: !updates.isChecking)
        let sections: [[NSMenuItem]] = [
            [
                menuItem(L("搜索"), #selector(openSearch)),
                menuItem(L("剪贴板"), #selector(openClipboard)),
                menuItem(L("系统监控"), #selector(openMonitor)),
            ],
            audioOutputMenu() + [
                submenu(L("倒计时"), countdownItems()),
                keepAwakeMenu(),
                menuItem(L("装忙"), #selector(startLookBusy)),
            ],
            [
                menuItem(L("息屏"), #selector(sleepDisplay)),
                menuItem(L("锁屏"), #selector(lockScreen)),
            ],
            [
                updateItem,
                menuItem(L("设置"), #selector(openSettings)),
                menuItem(L("退出 NotchDeck"), #selector(quit)),
            ],
        ]
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (index, section) in sections.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            section.forEach(menu.addItem)
        }
        // 菜单只在右键时临时挂上，否则左键也会弹菜单，打不开面板。
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func menuItem(_ title: String, _ action: Selector, tag: Int = 0, enabled: Bool = true, checked: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.tag = tag
        item.isEnabled = enabled
        item.state = checked ? .on : .off
        return item
    }

    private func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.items = items
        parent.submenu = menu
        return parent
    }

    /// 只有一个输出设备时没有可选的，不显示这一项。
    private func audioOutputMenu() -> [NSMenuItem] {
        let outputs = SystemVolume.outputDevices()
        guard outputs.count > 1 else { return [] }
        let current = SystemVolume.outputDevice()
        let items = outputs.map { menuItem($0.name, #selector(selectOutput(_:)), tag: Int($0.id), checked: $0.id == current) }
        return [submenu(L("音频输出"), items)]
    }

    /// 标签 0 表示一直开着，-1 表示关闭，其余是分钟数。
    private func keepAwakeMenu() -> NSMenuItem {
        let keepAwake = KeepAwake.shared
        func option(_ title: String, _ tag: Int) -> NSMenuItem {
            menuItem(title, #selector(setKeepAwake(_:)), tag: tag, checked: keepAwake.isOn && (keepAwake.duration ?? 0) == tag)
        }
        var items = [option(L("一直"), 0)] + KeepAwake.durations.map { option(formatDuration(minutes: $0), $0) }
        if keepAwake.isOn {
            items += [.separator(), menuItem(L("关闭"), #selector(setKeepAwake(_:)), tag: -1)]
        }
        let parent = submenu(L("防止休眠"), items)
        parent.state = keepAwake.isOn ? .on : .off
        return parent
    }

    private func countdownItems() -> [NSMenuItem] {
        guard CountdownTimer.shared.remaining == nil else {
            return [menuItem(L("取消"), #selector(cancelCountdown))]
        }
        return [5, 10, 25].map { menuItem(L("%d 分", $0), #selector(startCountdown(_:)), tag: $0) }
    }

    @objc private func openSearch() { app.togglePage(.search) }
    @objc private func openClipboard() { app.togglePage(.clipboard) }
    @objc private func openMonitor() { app.togglePage(.monitor) }
    @objc private func openSettings() { app.togglePage(.settings) }
    @objc private func selectOutput(_ sender: NSMenuItem) { SystemVolume.setOutputDevice(AudioObjectID(sender.tag)) }
    @objc private func startCountdown(_ sender: NSMenuItem) { CountdownTimer.shared.start(seconds: sender.tag * 60) }
    @objc private func cancelCountdown() { CountdownTimer.shared.reset() }
    @objc private func setKeepAwake(_ sender: NSMenuItem) {
        switch sender.tag {
        case -1: KeepAwake.shared.stop()
        case 0: KeepAwake.shared.start(minutes: nil)
        default: KeepAwake.shared.start(minutes: sender.tag)
        }
    }
    @objc private func startLookBusy() { LookBusyController.shared.show() }
    @objc private func sleepDisplay() { QuickControls.shared.sleepDisplay() }
    @objc private func lockScreen() { QuickControls.shared.lockScreen() }
    @objc private func checkForUpdates() { UpdateChecker.shared.check(userInitiated: true) }
    @objc private func updateNow() { UpdateChecker.shared.updateNow() }
    @objc private func quit() { NSApp.terminate(nil) }
}
