import AppKit
import SwiftUI

/// 框选识字和取色。都是点了才运行：识字调用系统截图框选一块区域，在本机识别文字后复制，截图用完就删；
/// 取色用系统自带的放大镜，复制 HEX 色值。复制的内容和普通复制一样进入剪贴板历史。
enum ScreenTools {
    private static var capturing = false
    private static var sampler: NSColorSampler?
    private static let requestedKey = "screenCaptureRequested"

    static func captureText() {
        AppDelegate.shared.closePanel()
        guard !capturing, hasScreenAccess() else { return }
        capturing = true
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("notchdeck-text-\(UUID().uuidString).png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // -i 框选（按空格可以选窗口），-x 不播放快门声。按 Esc 取消时不会生成文件。
        process.arguments = ["-i", "-x", file.path]
        process.terminationHandler = { _ in
            let image = NSImage(contentsOf: file)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            try? FileManager.default.removeItem(at: file)
            let text = image.flatMap(ClipboardStore.recognizeText) ?? ""
            DispatchQueue.main.async {
                capturing = false
                guard image != nil else { return }
                guard !text.isEmpty else {
                    Toasts.shared.show(L("没有识别到文字"), icon: "text.viewfinder")
                    return
                }
                copy(text)
                let lines = lineCount(text)
                Toasts.shared.show(lines > 1 ? L("已复制 %d 行文字", lines) : L("已复制识别出的文字"), icon: "text.viewfinder")
            }
        }
        do {
            try process.run()
        } catch {
            capturing = false
        }
    }

    static func pickColor() {
        AppDelegate.shared.closePanel()
        guard sampler == nil else { return }
        let sampler = NSColorSampler()
        self.sampler = sampler
        sampler.show { color in
            self.sampler = nil
            guard let color, let hex = hex(color) else { return }
            copy(hex)
            Toasts.shared.show(L("已复制 %@", hex), icon: "eyedropper")
        }
    }

    /// 截取屏幕要有“屏幕录制”权限。第一次用时请系统弹出授权窗口，之后还没打开就带用户去系统设置。
    private static func hasScreenAccess() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: requestedKey) {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        } else {
            defaults.set(true, forKey: requestedKey)
            CGRequestScreenCaptureAccess()
        }
        Toasts.shared.show(L("识字需要屏幕录制权限"), icon: "text.viewfinder")
        return false
    }

    private static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // MARK: - 检查程序直接调用

    static func lineCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isNewline).count
    }

    /// 转成 sRGB 后取整，格式 #RRGGBB。
    static func hex(_ color: NSColor) -> String? {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        let parts = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map { Int(($0 * 255).rounded().clamped(0, 255)) }
        return String(format: "#%02X%02X%02X", parts[0], parts[1], parts[2])
    }

    /// 剪贴板里的一条文字如果只是一个色值（#RGB 或 #RRGGBB），返回对应的颜色，用来显示色块。
    static func color(fromHex text: String) -> (red: Double, green: Double, blue: Double)? {
        var hex = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hex.hasPrefix("#") else { return nil }
        hex.removeFirst()
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6, hex.allSatisfy(\.isHexDigit), let value = UInt32(hex, radix: 16) else { return nil }
        return (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
    }
}

private extension CGFloat {
    func clamped(_ low: CGFloat, _ high: CGFloat) -> CGFloat { Swift.min(Swift.max(self, low), high) }
}
