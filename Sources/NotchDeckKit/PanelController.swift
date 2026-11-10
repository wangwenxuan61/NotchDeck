import AppKit
import Combine
import SwiftUI

enum Page: String { case home, monitor, apps, pinned, settings, clipboard, timer, music, customize, search, toggles, usage }

enum Metrics {
    static let contentWidth: CGFloat = 880
    static let contentHeight: CGFloat = 244
    static let sidePadding: CGFloat = 14
    static let cornerRadius: CGFloat = 18
    /// 面板左右和下方留给阴影的透明区域；上方不留，避免盖住菜单栏。
    static let shadowMargin: CGFloat = 24
    static let gapBelowMenuBar: CGFloat = 5
    static let screenMargin: CGFloat = 8
    static let panelWidth = contentWidth + sidePadding * 2
    static let windowWidth = panelWidth + shadowMargin * 2
    static let windowHeight = contentHeight + shadowMargin
}

final class PanelModel: ObservableObject {
    @Published var expanded = false
    @Published var page: Page = .home {
        didSet { AppDelegate.shared.refreshMonitorMode() }
    }
    @Published var homePage = 0

    func turnHomePage(by delta: Int) {
        let count = CardLayoutStore.shared.visiblePages.count
        let target = min(max(homePage + delta, 0), count - 1)
        guard count > 1, target != homePage else { return }
        withAnimation(.easeInOut(duration: 0.2)) { homePage = target }
    }
}

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class PanelController {
    let model = PanelModel()
    private let panel: FloatingPanel
    private var hideWork: DispatchWorkItem?
    private var appearanceSubscription: AnyCancellable?

    init() {
        panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: Metrics.windowWidth, height: Metrics.windowHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        appearanceSubscription = AppSettings.shared.$appearance.sink { [weak panel] mode in
            panel?.appearance = mode.nsAppearance
        }
        panel.contentView = NSHostingView(rootView: RootView(model: model))
    }

    /// 调试用：把面板内容导出为 PNG，不依赖屏幕录制权限。
    func snapshot(to path: String) {
        guard let view = panel.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: NSSize(width: rep.pixelsWide, height: rep.pixelsHigh))
        image.lockFocus()
        let isDark = view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        NSColor(white: isDark ? 0.15 : 0.72, alpha: 1).setFill()
        NSRect(origin: .zero, size: image.size).fill()
        rep.draw(in: NSRect(origin: .zero, size: image.size), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }

    private func place(midX: CGFloat, on screen: NSScreen) {
        let visible = screen.visibleFrame
        let half = Metrics.panelWidth / 2
        let lowest = visible.minX + Metrics.screenMargin + half
        let highest = visible.maxX - Metrics.screenMargin - half
        let x = min(max(midX, lowest), highest)
        let top = visible.maxY - Metrics.gapBelowMenuBar
        let frame = NSRect(
            x: x - Metrics.windowWidth / 2,
            y: top - Metrics.windowHeight,
            width: Metrics.windowWidth,
            height: Metrics.windowHeight
        )
        panel.setFrame(frame, display: false)
    }

    func open(midX: CGFloat, on screen: NSScreen) {
        hideWork?.cancel()
        hideWork = nil
        place(midX: midX, on: screen)
        if !panel.isVisible { panel.alphaValue = 0 }
        panel.orderFrontRegardless()
        panel.makeKey()
        // 窗口成为 key 后系统会自动聚焦第一个输入框，这里清掉，等用户点击时再输入。搜索页例外，打开就要能打字。
        DispatchQueue.main.async { [weak self] in
            guard let self, self.model.page != .search else { return }
            self.panel.makeFirstResponder(nil)
        }
        model.expanded = true
        animateAlpha(to: 1, duration: 0.16)
    }

    private func animateAlpha(to value: CGFloat, duration: TimeInterval) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            panel.animator().alphaValue = value
        }
    }

    func close() {
        guard model.expanded else { return }
        panel.makeFirstResponder(nil)
        model.expanded = false
        animateAlpha(to: 0, duration: 0.14)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.panel.orderOut(nil)
            self.model.page = .home
            self.model.homePage = 0
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: work)
    }
}
