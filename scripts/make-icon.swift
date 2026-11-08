// 生成 App 图标：swift scripts/make-icon.swift Resources/AppIcon.png
import AppKit

let side = 1024
guard CommandLine.arguments.count > 1,
      let rep = NSBitmapImageRep(
          bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
          hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
      ),
      let graphics = NSGraphicsContext(bitmapImageRep: rep) else {
    fatalError("usage: make-icon.swift <output.png>")
}
NSGraphicsContext.current = graphics
let c = graphics.cgContext
// 之后的坐标都以左上角为原点，y 向下。
c.translateBy(x: 0, y: CGFloat(side))
c.scaleBy(x: 1, y: -1)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 255) / 255,
        green: CGFloat((hex >> 8) & 255) / 255,
        blue: CGFloat(hex & 255) / 255,
        alpha: alpha
    )
}

func mix(_ a: UInt32, _ b: UInt32, _ t: CGFloat) -> CGColor {
    func part(_ value: UInt32, _ shift: UInt32) -> CGFloat { CGFloat((value >> shift) & 255) / 255 }
    func lerp(_ shift: UInt32) -> CGFloat { part(a, shift) + (part(b, shift) - part(a, shift)) * t }
    return CGColor(srgbRed: lerp(16), green: lerp(8), blue: lerp(0), alpha: 1)
}

func fill(_ path: CGPath, _ tint: CGColor) {
    c.addPath(path)
    c.setFillColor(tint)
    c.fillPath()
}

func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> CGPath {
    CGPath(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2), transform: nil)
}

// 图标主体：macOS 规范的 824pt 圆角方形。
let body = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 185, cornerHeight: 185, transform: nil)
c.saveGState()
c.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: color(0x000000, 0.30))
fill(body, color(0x20252F))
c.restoreGState()

c.saveGState()
c.addPath(body)
c.clip()
let background = CGGradient(
    colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
    colors: [color(0x20252F), color(0x0B0D12)] as CFArray,
    locations: nil
)!
c.drawLinearGradient(background, start: CGPoint(x: 220, y: 100), end: CGPoint(x: 800, y: 924), options: [])

// 仪表刻度环：开口朝下，占整圆的四分之三。
let center = CGPoint(x: 512, y: 540)
let radius: CGFloat = 256
let start = CGFloat.pi * 0.75
let sweep = CGFloat.pi * 1.5
c.setLineCap(.round)
c.setLineWidth(82)
c.setStrokeColor(color(0x2C3342))
c.addArc(center: center, radius: radius, startAngle: start, endAngle: start + sweep, clockwise: false)
c.strokePath()

// 彩色进度用很多小段拼出沿圆弧变化的渐变。
let filled: CGFloat = 0.74
let steps = 90
let stops: [UInt32] = [0x19C9A8, 0x2F7BFF, 0x8A4DFF, 0xF2555C]
for step in 0..<steps {
    let t = CGFloat(step) / CGFloat(steps)
    let scaled = t * CGFloat(stops.count - 1)
    let index = min(Int(scaled), stops.count - 2)
    c.setStrokeColor(mix(stops[index], stops[index + 1], scaled - CGFloat(index)))
    let from = start + sweep * filled * t
    let to = start + sweep * filled * (t + 1.6 / CGFloat(steps))
    c.setLineCap(step == 0 || step == steps - 1 ? .round : .butt)
    c.addArc(center: center, radius: radius, startAngle: from, endAngle: to, clockwise: false)
    c.strokePath()
}

// 指针和中心轴。
let tip = start + sweep * filled
c.setLineCap(.round)
c.setLineWidth(34)
c.setStrokeColor(color(0xF6F8FC))
c.move(to: center)
c.addLine(to: CGPoint(x: center.x + cos(tip) * 150, y: center.y + sin(tip) * 150))
c.strokePath()
fill(circle(center.x, center.y, 58), color(0xF6F8FC))
fill(circle(center.x, center.y, 22), color(0x20252F))
c.restoreGState()

NSGraphicsContext.current = nil
guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("encode failed") }
try! data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
