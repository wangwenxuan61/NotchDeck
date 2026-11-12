import SwiftUI

/// 做表格：一份按月的收入预测，光标一格格往下填数字、写公式，右边的图表跟着长出来。
final class SpreadsheetSim: BusySim {
    static let columns = ["Month", "Revenue", "COGS", "Gross profit", "Gross margin", "Opex", "EBITDA", "MoM growth"]
    static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    static let firstRow = 4   // 表头在第 3 行，数据从第 4 行开始

    private var rng: SplitMix64
    private(set) var sheet = 0
    private(set) var revenue: [Double] = []
    private(set) var cogs: [Double] = []
    private(set) var opex: [Double] = []
    /// 已经填好的格子数（按行从左到右，从 B 列开始，每行 7 格）。
    private(set) var filled = 0
    private(set) var typist = Typist()
    private var pause = 0.0

    init(seed: UInt64) {
        rng = SplitMix64(state: seed ^ 0x5EED_CE11)
        newSheet()
        // 打开时已经填了一部分。
        filled = rng.int(14..<40)
        startCell()
    }

    var sheetName: String { ["FY27 forecast", "Scenario B", "Board pack v3", "Q3 reforecast"][sheet % 4] }
    static let total = 12 * 7

    private func newSheet() {
        var r = rng.range(380_000, 620_000)
        let growth = rng.range(0.02, 0.06)
        revenue = []; cogs = []; opex = []
        for _ in 0..<12 {
            revenue.append((r / 100).rounded() * 100)
            cogs.append((r * rng.range(0.31, 0.38) / 100).rounded() * 100)
            opex.append((r * rng.range(0.29, 0.36) / 100).rounded() * 100)
            r *= 1 + growth + rng.range(-0.025, 0.03)
        }
        filled = 0
    }

    /// 当前要填的格子：行号（Excel 的行号）和列序号（1 = B 列）。
    var cursor: (row: Int, col: Int) { (Self.firstRow + filled / 7, 1 + filled % 7) }

    func advance(_ dt: Double) {
        if pause > 0 {
            pause -= dt
            if pause <= 0 && filled >= Self.total {
                sheet += 1
                newSheet()
                startCell()
            }
            return
        }
        typist.advance(dt, rng: &rng)
        if typist.isDone {
            filled += 1
            if filled >= Self.total {
                pause = rng.range(4, 7)
                typist.clear()
            } else {
                pause = rng.range(0.15, 0.6)
                startCell()
            }
        }
    }

    func boost() { typist.boost() }

    private func startCell() {
        typist.start(input(row: cursor.row, col: cursor.col), speed: 9...15, rng: &rng)
    }

    /// 用户“键入”的内容：数字列输入数字，其余列是公式。
    func input(row: Int, col: Int) -> String {
        let i = row - Self.firstRow
        switch col {
        case 1: return String(Int(revenue[i]))
        case 2: return String(Int(cogs[i]))
        case 3: return "=B\(row)-C\(row)"
        case 4: return "=D\(row)/B\(row)"
        case 5: return String(Int(opex[i]))
        case 6: return "=D\(row)-F\(row)"
        default: return i == 0 ? "=\"\"" : "=B\(row)/B\(row - 1)-1"
        }
    }

    func isFilled(row: Int, col: Int) -> Bool { (row - Self.firstRow) * 7 + col - 1 < filled }

    func value(row: Int, col: Int) -> String {
        let i = row - Self.firstRow
        let gross = revenue[i] - cogs[i]
        switch col {
        case 1: return money(revenue[i])
        case 2: return money(cogs[i])
        case 3: return money(gross)
        case 4: return String(format: "%.1f%%", gross / revenue[i] * 100)
        case 5: return money(opex[i])
        case 6: return money(gross - opex[i])
        default: return i == 0 ? "" : String(format: "%+.1f%%", (revenue[i] / revenue[i - 1] - 1) * 100)
        }
    }

    func money(_ v: Double) -> String { (v < 0 ? "-$" : "$") + grouped(Int(abs(v))) }

    /// 已经填好收入的月份数，图表只画这些。
    var monthsWithRevenue: Int { (0..<12).filter { isFilled(row: Self.firstRow + $0, col: 1) }.count }
}

private enum XL {
    static let green = Color(hex: 0x1F6E43)
    static let ribbon = Color(hex: 0xF3F3F3)
    static let grid = Color(hex: 0xE1E1E1)
    static let header = Color(hex: 0xF0F0F0)
    static let headerSelected = Color(hex: 0xD3E8DA)
    static let text = Color(hex: 0x222222)
    static let dim = Color(hex: 0x666666)
    static let select = Color(hex: 0x217346)
    static let bar = Color(hex: 0x4472C4)
    static let line = Color(hex: 0xED7D31)
    static let rowH: CGFloat = 22
    static let font = Font.system(size: 12.5)
}

struct SpreadsheetView: View {
    let sim: SpreadsheetSim
    let t: Double
    private static let widths: [CGFloat] = [70, 110, 110, 120, 110, 110, 110, 110]

    var body: some View {
        GeometryReader { geo in
            let portrait = geo.size.height > geo.size.width
            VStack(spacing: 0) {
                titleBar
                ribbon
                formulaBar
                AdaptiveStack(portrait: portrait) {
                    grid
                    chartPane
                        .frame(width: portrait ? nil : geo.size.width * 0.34, height: portrait ? geo.size.height * 0.3 : nil)
                }
                sheetTabs
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .background(Color.white)
        }
    }

    private var titleBar: some View {
        HStack(spacing: 14) {
            Image(systemName: "tablecells.fill")
            Text("AutoSave").font(.system(size: 12))
            Capsule().fill(.white.opacity(0.9)).frame(width: 28, height: 14)
                .overlay(Circle().fill(XL.green).frame(width: 10).offset(x: 6))
            Spacer()
            Text("revenue_model_FY27.xlsx — Saved").font(.system(size: 13, weight: .medium))
            Spacer()
            Image(systemName: "magnifyingglass")
            Text("Share").font(.system(size: 12)).padding(.horizontal, 10).padding(.vertical, 3)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.white.opacity(0.6)))
        }
        .foregroundColor(.white)
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(XL.green)
    }

    private var ribbon: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 20) {
                ForEach(["Home", "Insert", "Draw", "Page Layout", "Formulas", "Data", "Review", "View"], id: \.self) { tab in
                    Text(tab).font(.system(size: 12.5, weight: tab == "Home" ? .semibold : .regular))
                        .foregroundColor(tab == "Home" ? XL.green : XL.text)
                        .overlay(Rectangle().fill(tab == "Home" ? XL.green : .clear).frame(height: 2).offset(y: 12), alignment: .bottom)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 30)
            HStack(spacing: 18) {
                ribbonGroup(["doc.on.clipboard", "scissors", "doc.on.doc"])
                Text("Aptos (Body)").font(.system(size: 12)).padding(.horizontal, 8).padding(.vertical, 3)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(XL.grid))
                Text("11").font(.system(size: 12)).padding(.horizontal, 8).padding(.vertical, 3)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(XL.grid))
                ribbonGroup(["bold", "italic", "underline", "paintbrush"])
                ribbonGroup(["text.alignleft", "text.aligncenter", "text.alignright", "arrow.left.and.right.text.vertical"])
                Text("Currency").font(.system(size: 12)).padding(.horizontal, 8).padding(.vertical, 3)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(XL.grid))
                ribbonGroup(["dollarsign", "percent", "number"])
                ribbonGroup(["tablecells", "square.grid.3x3.square", "paintpalette"])
                ribbonGroup(["sum", "arrow.up.arrow.down", "line.3.horizontal.decrease"])
                Spacer()
            }
            .foregroundColor(XL.text)
            .padding(.horizontal, 14)
            .frame(height: 40)
        }
        .background(XL.ribbon)
        .overlay(Rectangle().fill(XL.grid).frame(height: 1), alignment: .bottom)
    }

    private func ribbonGroup(_ symbols: [String]) -> some View {
        HStack(spacing: 12) { ForEach(symbols, id: \.self) { Image(systemName: $0).font(.system(size: 13)) } }
    }

    private var cellName: String {
        let c = sim.cursor
        return "\(Character(UnicodeScalar(65 + c.col)!))\(c.row)"
    }

    private var formulaBar: some View {
        HStack(spacing: 0) {
            Text(cellName).font(XL.font).frame(width: 80, alignment: .leading).padding(.leading, 10)
            Rectangle().fill(XL.grid).frame(width: 1)
            Text("✕  ✓  fx").font(.system(size: 12)).foregroundColor(XL.dim).padding(.horizontal, 12)
            Rectangle().fill(XL.grid).frame(width: 1)
            Text(sim.typist.text).font(XL.font).foregroundColor(XL.text).padding(.leading, 10)
            Spacer()
        }
        .frame(height: 26)
        .overlay(Rectangle().fill(XL.grid).frame(height: 1), alignment: .bottom)
    }

    private func letter(_ i: Int) -> String { String(Character(UnicodeScalar(65 + i)!)) }

    private var grid: some View {
        GeometryReader { geo in
            let rows = Int(geo.size.height / XL.rowH)
            let extra = max(0, Int((geo.size.width - 40 - Self.widths.reduce(0, +)) / 90) + 1)
            let widths = Self.widths + Array(repeating: 90, count: extra)
            let cursor = sim.cursor
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    cell("", width: 40, header: true)
                    ForEach(widths.indices, id: \.self) { cell(letter($0), width: widths[$0], header: true, selected: $0 == cursor.col, center: true) }
                }
                ForEach(1..<max(2, rows), id: \.self) { row in
                    HStack(spacing: 0) {
                        cell("\(row)", width: 40, header: true, selected: row == cursor.row, center: true)
                        ForEach(widths.indices, id: \.self) { col in
                            content(row: row, col: col, width: widths[col], active: row == cursor.row && col == cursor.col)
                        }
                    }
                }
            }
        }
        .clipped()
    }

    @ViewBuilder
    private func content(row: Int, col: Int, width: CGFloat, active: Bool) -> some View {
        let first = SpreadsheetSim.firstRow
        if active {
            cell(sim.typist.text, width: width).overlay(Rectangle().stroke(XL.select, lineWidth: 2))
        } else if row == 1 && col == 0 {
            cell("\(sim.sheetName) · revenue model (USD)", width: width, bold: true, overflow: true)
        } else if row == first - 1 && col < SpreadsheetSim.columns.count {
            cell(SpreadsheetSim.columns[col], width: width, bold: true, fill: Color(hex: 0xE2EFDA), trailing: col > 0)
        } else if row >= first && row < first + 12 && col == 0 {
            cell(SpreadsheetSim.months[row - first], width: width)
        } else if row >= first && row < first + 12 && col >= 1 && col <= 7 && sim.isFilled(row: row, col: col) {
            let text = sim.value(row: row, col: col)
            cell(text, width: width, color: text.hasPrefix("-") ? .red : XL.text, trailing: true)
        } else if let text = quarterly(row: row, col: col) {
            cell(text, width: width, bold: row == first + 15, fill: row == first + 15 ? Color(hex: 0xDDEBF7) : .clear, trailing: col > 0)
        } else if row == first + 12 && col == 0 {
            cell("Total", width: width, bold: true)
        } else if row == first + 12 && [1, 2, 3, 5, 6].contains(col) && sim.filled >= SpreadsheetSim.total {
            cell(total(col), width: width, bold: true, trailing: true)
        } else {
            cell("", width: width)
        }
    }

    /// 月度表下面的季度汇总：一个季度的三个月都填完 EBITDA 才显示数字。
    private func quarterly(row: Int, col: Int) -> String? {
        let header = SpreadsheetSim.firstRow + 15
        guard row >= header && row <= header + 4 && col <= 3 else { return nil }
        if row == header { return ["Quarter", "Revenue", "EBITDA", "EBITDA margin"][col] }
        let q = row - header - 1
        if col == 0 { return "Q\(q + 1) FY27" }
        let months = (q * 3)..<(q * 3 + 3)
        guard months.allSatisfy({ sim.isFilled(row: SpreadsheetSim.firstRow + $0, col: 6) }) else { return "" }
        let revenue = months.map { sim.revenue[$0] }.reduce(0, +)
        let ebitda = months.map { sim.revenue[$0] - sim.cogs[$0] - sim.opex[$0] }.reduce(0, +)
        return [sim.money(revenue), sim.money(ebitda), String(format: "%.1f%%", ebitda / revenue * 100)][col - 1]
    }

    private func total(_ col: Int) -> String {
        let r = sim.revenue.reduce(0, +), c = sim.cogs.reduce(0, +), o = sim.opex.reduce(0, +)
        switch col {
        case 1: return sim.money(r)
        case 2: return sim.money(c)
        case 3: return sim.money(r - c)
        case 5: return sim.money(o)
        default: return sim.money(r - c - o)
        }
    }

    private func cell(_ text: String, width: CGFloat, header: Bool = false, selected: Bool = false, bold: Bool = false,
                      fill: Color = .clear, color: Color = XL.text, trailing: Bool = false, center: Bool = false,
                      overflow: Bool = false) -> some View {
        Text(text)
            .font(header ? .system(size: 11.5) : XL.font)
            .fontWeight(bold ? .semibold : .regular)
            .foregroundColor(header ? (selected ? XL.green : XL.dim) : color)
            .lineLimit(1)
            .fixedSize(horizontal: overflow, vertical: false)
            .padding(.horizontal, 5)
            .frame(width: width, height: XL.rowH, alignment: center ? .center : trailing ? .trailing : .leading)
            .background(header ? (selected ? XL.headerSelected : XL.header) : fill)
            .overlay(Rectangle().stroke(XL.grid, lineWidth: 0.5))
            .zIndex(overflow ? 1 : 0)
    }

    private var chartPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Revenue and gross margin by month").font(.system(size: 14, weight: .semibold)).foregroundColor(XL.text)
            HStack(spacing: 14) {
                legend("Revenue", XL.bar)
                legend("Gross margin", XL.line)
            }
            Canvas { ctx, size in
                let n = sim.monthsWithRevenue
                let top = niceCeiling((sim.revenue.max() ?? 1) * 1.1)
                let plot = CGRect(x: 54, y: 8, width: size.width - 100, height: size.height - 30)
                for i in 0...4 {
                    let y = plot.maxY - plot.height * Double(i) / 4
                    ctx.stroke(Path { $0.move(to: CGPoint(x: plot.minX, y: y)); $0.addLine(to: CGPoint(x: plot.maxX, y: y)) },
                               with: .color(XL.grid), lineWidth: 1)
                    ctx.draw(Text("$\(Int(top * Double(i) / 4 / 1000))k").font(.system(size: 10)).foregroundColor(XL.dim),
                             at: CGPoint(x: plot.minX - 6, y: y), anchor: .trailing)
                    // 右侧是毛利率的刻度。
                    ctx.draw(Text("\(i * 25)%").font(.system(size: 10)).foregroundColor(XL.line),
                             at: CGPoint(x: plot.maxX + 8, y: y), anchor: .leading)
                }
                let w = plot.width / 12
                var margin = Path()
                for i in 0..<12 {
                    let x = plot.minX + w * Double(i)
                    ctx.draw(Text(SpreadsheetSim.months[i]).font(.system(size: 10)).foregroundColor(XL.dim),
                             at: CGPoint(x: x + w / 2, y: plot.maxY + 10), anchor: .center)
                    guard i < n else { continue }
                    let h = plot.height * sim.revenue[i] / top
                    ctx.fill(Path(CGRect(x: x + w * 0.18, y: plot.maxY - h, width: w * 0.64, height: h)), with: .color(XL.bar))
                    if sim.isFilled(row: SpreadsheetSim.firstRow + i, col: 4) {
                        let m = (sim.revenue[i] - sim.cogs[i]) / sim.revenue[i]
                        let p = CGPoint(x: x + w / 2, y: plot.maxY - plot.height * m)
                        margin.isEmpty ? margin.move(to: p) : margin.addLine(to: p)
                        ctx.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)), with: .color(XL.line))
                    }
                }
                ctx.stroke(margin, with: .color(XL.line), lineWidth: 2)
            }
        }
        .padding(16)
        .background(Color.white)
        .overlay(Rectangle().fill(XL.grid).frame(width: 1), alignment: .leading)
    }

    private func legend(_ title: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 12, height: 8)
            Text(title).font(.system(size: 11)).foregroundColor(XL.dim)
        }
    }

    private var sheetTabs: some View {
        let row = sim.cursor.row
        let sum = (0..<12).filter { sim.isFilled(row: SpreadsheetSim.firstRow + $0, col: 1) }.map { sim.revenue[$0] }.reduce(0, +)
        return HStack(spacing: 0) {
            ForEach([sim.sheetName, "Assumptions", "Raw data", "Charts"], id: \.self) { name in
                Text(name).font(.system(size: 12, weight: name == sim.sheetName ? .semibold : .regular))
                    .foregroundColor(name == sim.sheetName ? XL.green : XL.dim)
                    .padding(.horizontal, 14).frame(height: 26)
                    .background(name == sim.sheetName ? Color.white : XL.ribbon)
            }
            Image(systemName: "plus.circle").foregroundColor(XL.dim).padding(.horizontal, 10)
            Spacer()
            Text(sim.typist.isActive ? "Enter" : "Ready").foregroundColor(XL.dim)
            Text("   Revenue sum: \(sim.money(sum))   Row \(row)").foregroundColor(XL.dim)
            Text("   ▭  ▦  ▤   100%").foregroundColor(XL.dim).padding(.trailing, 12)
        }
        .font(.system(size: 12))
        .frame(height: 26)
        .background(XL.ribbon)
        .overlay(Rectangle().fill(XL.grid).frame(height: 1), alignment: .top)
    }
}
