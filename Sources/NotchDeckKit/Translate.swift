import AppKit
import SwiftUI
import Translation

/// 截图翻译：框选屏幕上的一块，识别出文字后在旁边弹一个小窗，接着用系统自带的翻译弹窗翻译。
/// 翻译由 macOS 在本机完成，模型也由系统管理；系统翻译弹窗需要 macOS 14.4。
enum TranslateWindow {
    private static var panel: NSPanel?
    private static var observer: NSObjectProtocol?

    static var isAvailable: Bool {
        if #available(macOS 14.4, *) { return true }
        return false
    }

    static func captureAndTranslate() {
        ScreenTools.captureRegion { text in show(text, near: NSEvent.mouseLocation) }
    }

    /// 在 point 附近显示识别出的文字。框选结束时鼠标停在选区的一角，窗口就放在那旁边。
    static func show(_ text: String, near point: NSPoint) {
        guard #available(macOS 14.4, *) else { return }
        close()
        let panel = TranslatePanel(contentRect: NSRect(x: 0, y: 0, width: TranslateCard.width, height: 100),
                                   styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        let host = NSHostingView(rootView: TranslateCard(text: text))
        panel.contentView = host
        let size = host.fittingSize
        panel.setContentSize(size)
        panel.setFrameOrigin(origin(for: panel.frame.size, near: point))
        self.panel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        // 点到别的 App 时收起；翻译弹窗属于 NotchDeck，在弹窗里操作不会收起。
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            close()
        }
    }

    static func close() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        panel?.orderOut(nil)
        panel = nil
    }

    /// 放在鼠标右下方；放不下时挪到屏幕里面。
    static func origin(for size: NSSize, near point: NSPoint, in visible: NSRect? = nil) -> NSPoint {
        let frame = visible ?? (NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main)?.visibleFrame ?? .zero
        var x = point.x + 12
        var y = point.y - 12 - size.height
        if x + size.width > frame.maxX { x = point.x - 12 - size.width }
        if y < frame.minY { y = point.y + 12 }
        x = min(max(x, frame.minX + 8), frame.maxX - size.width - 8)
        y = min(max(y, frame.minY + 8), frame.maxY - size.height - 8)
        return NSPoint(x: x, y: y)
    }
}

/// 按 Esc 关掉小窗。
private final class TranslatePanel: NSPanel {
    override func cancelOperation(_ sender: Any?) { TranslateWindow.close() }
}

@available(macOS 14.4, *)
private struct TranslateCard: View {
    static let width: CGFloat = 380
    let text: String
    @State private var translating = false
    @State private var copied = false

    /// 文字区域的高度：按行数估算，太长时可以滚动。
    private var textHeight: CGFloat {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { max(1, Int(ceil(Double($0.count) / 42))) }
            .reduce(0, +)
        return min(220, max(36, CGFloat(lines) * 18 + 8))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "text.viewfinder").foregroundStyle(Theme.secondary)
                Text(L("识别出的文字")).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                Spacer()
            }
            ScrollView(.vertical) {
                Text(text)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: textHeight)
            HStack(spacing: 8) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = true
                } label: {
                    Label(copied ? L("已复制") : L("复制原文"), systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                Spacer()
                Button {
                    translating = true
                } label: {
                    Label(L("翻译"), systemImage: "translate")
                }
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.top, 30)
        .padding(.bottom, 12)
        .frame(width: Self.width)
        .translationPresentation(isPresented: $translating, text: text, arrowEdge: .bottom)
        .onAppear {
            // 窗口出现后再弹出翻译，弹窗要依附在已经显示的窗口上。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { translating = true }
        }
    }
}

/// 首页底部的翻译按钮。
struct TranslateButton: View {
    var body: some View {
        if TranslateWindow.isAvailable {
            Button { TranslateWindow.captureAndTranslate() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "translate").foregroundStyle(Theme.teal)
                    Text(L("翻译")).font(.system(size: 13, weight: .medium)).lineLimit(1).fixedSize()
                }
                .padding(.horizontal, 14)
                .frame(height: 36)
                .capsuleFill(Theme.control)
            }
            .buttonStyle(.plain)
            .help(L("框选屏幕上的文字并翻译（⌃⌥Y）"))
        }
    }
}
