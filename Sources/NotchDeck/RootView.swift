import AppKit
import SwiftUI

struct VisualEffect: NSViewRepresentable {
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        view.maskImage = Self.mask(radius: cornerRadius)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}

    /// 窗口后方的毛玻璃不受 SwiftUI 裁剪影响，圆角要用 maskImage 设置。
    private static func mask(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

struct RootView: View {
    @ObservedObject var model: PanelModel
    @ObservedObject private var language = LanguageStore.shared

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous)
        ZStack(alignment: .top) {
            VisualEffect(cornerRadius: Metrics.cornerRadius)
            Theme.panelTint
            ExpandedContent(model: model)
                .frame(width: Metrics.contentWidth, height: Metrics.contentHeight, alignment: .top)
                // 换语言时重建整个界面，所有文字一起更新。
                .id(language.current)
        }
        .frame(width: Metrics.panelWidth, height: Metrics.contentHeight)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Theme.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.22), radius: 12, y: 4)
        .frame(width: Metrics.windowWidth, height: Metrics.windowHeight, alignment: .top)
        .foregroundStyle(Theme.primary)
    }
}

extension InsettableShape {
    /// 卡片样式：浅色填充加一圈细边。
    func cardFill(_ color: Color = Theme.card) -> some View {
        fill(color).overlay(strokeBorder(Theme.hairline, lineWidth: 1))
    }
}

extension View {
    /// 胶囊形按钮的底色，整个胶囊都能点击。
    func capsuleFill(_ color: Color) -> some View {
        background(Capsule().fill(color)).contentShape(Capsule())
    }
}

/// 所有颜色都分浅色和深色两个值，由面板当前的外观决定使用哪一个。
enum Theme {
    private static func adaptive(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }

    private static func rgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }

    private static func black(_ alpha: CGFloat) -> NSColor { NSColor(white: 0, alpha: alpha) }
    private static func white(_ alpha: CGFloat) -> NSColor { NSColor(white: 1, alpha: alpha) }

    static let teal = adaptive(rgb(0.03, 0.56, 0.47), rgb(0.36, 0.84, 0.72))
    static let coral = adaptive(rgb(0.92, 0.33, 0.36), rgb(0.95, 0.47, 0.47))
    static let blue = adaptive(rgb(0.00, 0.48, 1.00), rgb(0.32, 0.64, 0.98))
    static let purple = adaptive(rgb(0.55, 0.30, 0.88), rgb(0.68, 0.45, 0.95))
    static let orange = adaptive(rgb(0.92, 0.52, 0.05), rgb(0.98, 0.65, 0.20))
    static let primary = adaptive(black(0.86), white(0.92))
    static let secondary = adaptive(black(0.58), white(0.62))
    static let tertiary = adaptive(black(0.38), white(0.42))
    static let panelTint = adaptive(white(0.62), black(0.48))
    static let card = adaptive(white(0.72), white(0.09))
    static let cardHover = adaptive(white(0.90), white(0.15))
    static let control = adaptive(black(0.06), white(0.09))
    static let controlHover = adaptive(black(0.11), white(0.16))
    static let track = adaptive(black(0.10), white(0.14))
    static let hairline = adaptive(black(0.08), white(0.12))
}

struct ExpandedContent: View {
    @ObservedObject var model: PanelModel
    @ObservedObject private var toasts = Toasts.shared

    @ViewBuilder private var detailPage: some View {
        switch model.page {
        case .home: EmptyView()
        case .monitor: MonitorPage(model: model)
        case .apps: AllAppsPage(model: model)
        case .pinned: PinnedAppsPage(model: model)
        case .settings: SettingsPage(model: model)
        case .clipboard: ClipboardPage(model: model)
        case .timer: TimerPage(model: model)
        case .music: MusicPage(model: model)
        case .customize: CustomizePage(model: model)
        case .search: SearchPage(model: model)
        case .toggles: QuickControlsPage(model: model)
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 8) {
                TopBar(model: model).frame(height: 30)
                if model.page == .home {
                    HomeCards(model: model).frame(height: 128)
                    DockRow(model: model).frame(height: 46)
                } else {
                    detailPage.frame(height: 182)
                }
            }
            .padding(.top, 12)

            if let toast = toasts.current {
                Label(toast.text, systemImage: toast.icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.black.opacity(0.82)))
                    .padding(.bottom, 16)
                    .transition(.opacity)
            }
        }
    }
}

struct TopBar: View {
    @ObservedObject var model: PanelModel
    @ObservedObject private var monitor = SystemMonitor.shared
    @ObservedObject private var layout = CardLayoutStore.shared
    @ObservedObject private var updates = UpdateChecker.shared

    private var batterySymbol: String {
        if monitor.isCharging || monitor.onExternalPower { return "battery.100percent.bolt" }
        switch monitor.batteryPercent ?? 100 {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    private func tab(_ symbol: String, _ page: Page, help: String) -> some View {
        IconButton(symbol: symbol, selected: model.page == page, help: help) {
            model.page = model.page == page ? .home : page
        }
    }

    private func pagerArrow(_ symbol: String, delta: Int, enabled: Bool) -> some View {
        Button { model.turnHomePage(by: delta) } label: {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(enabled ? Theme.primary : Theme.tertiary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    @ViewBuilder private var pager: some View {
        let count = layout.visiblePages.count
        if model.page == .home && count > 1 {
            let current = min(model.homePage, count - 1)
            HStack(spacing: 4) {
                pagerArrow("chevron.left", delta: -1, enabled: current > 0)
                ForEach(0..<count, id: \.self) { index in
                    Circle().fill(index == current ? Theme.primary : Theme.track).frame(width: 6, height: 6)
                }
                pagerArrow("chevron.right", delta: 1, enabled: current < count - 1)
            }
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            IconButton(symbol: "square.grid.2x2", selected: model.page == .home, help: L("首页")) { model.page = .home }
            tab("doc.on.clipboard", .clipboard, help: L("剪贴板"))
            tab("timer", .timer, help: L("计时器"))
            tab("music.note", .music, help: L("音乐"))

            Spacer()

            if let percent = monitor.batteryPercent {
                HStack(spacing: 5) {
                    Image(systemName: batterySymbol).font(.system(size: 13))
                    Text("\(percent)%").font(.system(size: 12, weight: .medium)).monospacedDigit()
                }
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(Capsule().fill(Theme.control))
            }
            tab("magnifyingglass", .search, help: L("搜索"))
            tab("switch.2", .toggles, help: L("快捷开关"))
            IconButton(symbol: "gearshape.fill", selected: model.page == .settings, help: L("设置")) {
                model.page = model.page == .settings ? .home : .settings
            }
            .overlay(alignment: .topTrailing) {
                if updates.latestVersion != nil {
                    Circle().fill(Theme.coral).frame(width: 8, height: 8)
                }
            }
        }
        .overlay { pager }
    }
}
