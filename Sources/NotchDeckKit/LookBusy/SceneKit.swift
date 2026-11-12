import SwiftUI

/// 新场景共用的小工具：随机游走的数值、定长的历史曲线和画折线图。

/// 围绕基准值随机游走，又会慢慢回到基准，看起来像真实的监控数据。
struct Walk {
    var value: Double
    let base: Double
    let spread: Double
    let lo: Double
    let hi: Double

    init(_ base: Double, spread: Double, lo: Double = 0, hi: Double = .greatestFiniteMagnitude) {
        value = base
        self.base = base
        self.spread = spread
        self.lo = lo
        self.hi = hi
    }

    @discardableResult
    mutating func step(_ rng: inout SplitMix64, pull: Double = 0.12) -> Double {
        value += (base - value) * pull + rng.range(-spread, spread)
        value = min(hi, max(lo, value))
        return value
    }
}

/// 只保留最近 capacity 个点的曲线。
struct History {
    private(set) var points: [Double] = []
    let capacity: Int

    init(capacity: Int) { self.capacity = capacity }

    mutating func push(_ value: Double) {
        points.append(value)
        if points.count > capacity { points.removeFirst(points.count - capacity) }
    }

    var last: Double { points.last ?? 0 }
}

/// 让曲线的上限落在好看的整数上：0.8 -> 1、37 -> 40、1234 -> 1500。
func niceCeiling(_ value: Double) -> Double {
    guard value > 0 else { return 1 }
    let magnitude = pow(10, floor(log10(value)))
    for step in [1.0, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10] where step * magnitude >= value {
        return step * magnitude
    }
    return 10 * magnitude
}

struct ChartStyle {
    let grid: Color
    let label: Color
    var font = Font.system(size: 10, design: .monospaced)
}

/// 在 Canvas 里画几条折线，带横向网格和纵轴刻度。yMax 不传时按数据自动取整。
func drawLineChart(_ ctx: GraphicsContext, size: CGSize, series: [[Double]], colors: [Color], style: ChartStyle,
                   yMax: Double? = nil, fill: Bool = false, format: (Double) -> String = { String(format: "%.0f", $0) },
                   xLabels: [String] = []) {
    let top = niceCeiling(yMax ?? (series.flatMap { $0 }.max() ?? 1) * 1.1)
    let plot = CGRect(x: 46, y: 6, width: max(10, size.width - 52), height: max(10, size.height - (xLabels.isEmpty ? 12 : 26)))
    for i in 0...4 {
        let v = top * Double(i) / 4
        let y = plot.maxY - plot.height * Double(i) / 4
        ctx.stroke(Path { $0.move(to: CGPoint(x: plot.minX, y: y)); $0.addLine(to: CGPoint(x: plot.maxX, y: y)) },
                   with: .color(style.grid), lineWidth: 1)
        ctx.draw(Text(format(v)).font(style.font).foregroundColor(style.label), at: CGPoint(x: plot.minX - 6, y: y), anchor: .trailing)
    }
    for (i, label) in xLabels.enumerated() where xLabels.count > 1 {
        let x = plot.minX + plot.width * Double(i) / Double(xLabels.count - 1)
        ctx.draw(Text(label).font(style.font).foregroundColor(style.label), at: CGPoint(x: x, y: plot.maxY + 11),
                 anchor: i == 0 ? .leading : i == xLabels.count - 1 ? .trailing : .center)
    }
    for (index, points) in series.enumerated() where points.count > 1 {
        let color = colors[index % colors.count]
        var line = Path(), area = Path()
        for (i, v) in points.enumerated() {
            let p = CGPoint(x: plot.minX + plot.width * Double(i) / Double(points.count - 1),
                            y: plot.maxY - plot.height * min(v, top) / top)
            if i == 0 {
                line.move(to: p)
                area.move(to: CGPoint(x: p.x, y: plot.maxY))
                area.addLine(to: p)
            } else {
                line.addLine(to: p)
                area.addLine(to: p)
            }
        }
        if fill {
            area.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
            area.closeSubpath()
            ctx.fill(area, with: .color(color.opacity(0.14)))
        }
        ctx.stroke(line, with: .color(color), lineWidth: 1.5)
    }
}

/// 终端、日志一类往上滚的文字：只画放得下的最后几行，最新的一行在最下面。
/// footerLines 是下面 footer 占的行数，比如命令提示符。
struct LogTail<Line, Row: View, Footer: View>: View {
    let lines: [Line]
    let lineHeight: CGFloat
    var footerLines = 0
    @ViewBuilder let row: (Line) -> Row
    @ViewBuilder let footer: () -> Footer

    var body: some View {
        GeometryReader { geo in
            let n = max(1, Int(geo.size.height / lineHeight) - footerLines)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.suffix(n).enumerated()), id: \.offset) { _, line in
                    row(line).lineLimit(1).frame(height: lineHeight, alignment: .leading)
                }
                footer()
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .bottomLeading)
        }
        .clipped()
    }
}

extension LogTail where Footer == EmptyView {
    init(lines: [Line], lineHeight: CGFloat, @ViewBuilder row: @escaping (Line) -> Row) {
        self.init(lines: lines, lineHeight: lineHeight, row: row, footer: { EmptyView() })
    }
}

/// 按竖屏还是横屏排列：横屏左右放，竖屏上下放。
struct AdaptiveStack<Content: View>: View {
    let portrait: Bool
    var spacing: CGFloat = 0
    @ViewBuilder let content: Content

    var body: some View {
        if portrait {
            VStack(spacing: spacing) { content }
        } else {
            HStack(spacing: spacing) { content }
        }
    }
}

/// 场景里的时钟文字。模拟从打开装忙的那一刻开始走。
struct SceneClock {
    let start = Date()
    private let formatter: DateFormatter

    init(_ format: String = "HH:mm:ss") {
        formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
    }

    func string(after seconds: Double) -> String { formatter.string(from: start.addingTimeInterval(seconds)) }
}
