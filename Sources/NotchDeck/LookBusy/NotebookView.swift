import SwiftUI

private enum NB {
    static let bg = Color.white
    static let chrome = Color(hex: 0xEEEEEE)
    static let border = Color(hex: 0xE0E0E0)
    static let side = Color(hex: 0xFAFAFA)
    static let text = Color(hex: 0x212121)
    static let dim = Color(hex: 0x757575)
    static let inPrompt = Color(hex: 0x303F9F)
    static let outPrompt = Color(hex: 0xD84315)
    static let cell = Color(hex: 0xF5F5F5)
    static let active = Color(hex: 0x1976D2)
    static let mono = Font.system(size: 13, design: .monospaced)
    static let mpl = [Color(hex: 0x1F77B4), Color(hex: 0xFF7F0E), Color(hex: 0x2CA02C), Color(hex: 0xD62728)]
}

struct NotebookView: View {
    let sim: NotebookSim
    let t: Double

    var body: some View {
        VStack(spacing: 0) {
            menuBar
            HStack(spacing: 0) {
                iconRail
                fileBrowser.frame(width: 270)
                Rectangle().fill(NB.border).frame(width: 1)
                VStack(spacing: 0) {
                    tabBar
                    toolbar
                    cellsArea
                }
            }
            statusBar
        }
        .background(NB.bg)
    }

    private var menuBar: some View {
        HStack(spacing: 18) {
            Image(systemName: "circle.hexagongrid.fill").foregroundColor(Color(hex: 0xF37726))
            ForEach(["File", "Edit", "View", "Run", "Kernel", "Tabs", "Settings", "Help"], id: \.self) { Text($0) }
            Spacer()
        }
        .font(.system(size: 13)).foregroundColor(NB.text)
        .padding(.horizontal, 12).frame(height: 30)
        .background(NB.bg)
        .overlay(Rectangle().fill(NB.border).frame(height: 1), alignment: .bottom)
    }

    private var iconRail: some View {
        VStack(spacing: 22) {
            ForEach(["folder.fill", "stop.circle", "list.bullet.indent", "puzzlepiece.extension"], id: \.self) { name in
                Image(systemName: name).font(.system(size: 17)).foregroundColor(name == "folder.fill" ? NB.active : NB.dim)
            }
            Spacer()
        }
        .padding(.top, 14).frame(width: 40).frame(maxHeight: .infinity)
        .background(NB.chrome)
    }

    private var fileBrowser: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "plus.rectangle.fill").foregroundColor(NB.active)
                Image(systemName: "folder.badge.plus"); Image(systemName: "arrow.up.doc"); Image(systemName: "arrow.clockwise")
            }
            .font(.system(size: 14)).foregroundColor(NB.dim).padding(.horizontal, 12).frame(height: 38)
            Text("Filter files by name").font(.system(size: 12)).foregroundColor(Color(hex: 0xAAAAAA))
                .padding(.horizontal, 8).frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(NB.border)).padding(.horizontal, 12)
            HStack(spacing: 4) { Image(systemName: "folder"); Text("/ analytics /") }
                .font(.system(size: 12)).foregroundColor(NB.dim).padding(12)
            HStack { Text("Name"); Spacer(); Text("Last Modified") }
                .font(.system(size: 11.5, weight: .semibold)).foregroundColor(NB.dim)
                .padding(.horizontal, 12).frame(height: 24)
                .overlay(Rectangle().fill(NB.border).frame(height: 1), alignment: .bottom)
            ForEach(sim.files, id: \.name) { f in
                HStack(spacing: 6) {
                    Image(systemName: f.dir ? "folder.fill" : f.name.hasSuffix(".ipynb") ? "book.closed.fill" : "doc.text")
                        .font(.system(size: 11))
                        .foregroundColor(f.dir ? Color(hex: 0x90A4AE) : f.name.hasSuffix(".ipynb") ? Color(hex: 0xEF6C00) : NB.dim)
                    Text(f.name).lineLimit(1)
                    Spacer()
                    Text(f.modified).foregroundColor(NB.dim)
                }
                .font(.system(size: 12.5)).foregroundColor(NB.text)
                .padding(.horizontal, 12).frame(height: 26)
                .background(f.name == sim.notebook ? Color(hex: 0xE3F2FD) : Color.clear)
            }
            Spacer()
        }
        .background(NB.side)
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "book.closed.fill").font(.system(size: 11)).foregroundColor(Color(hex: 0xEF6C00))
                Text(sim.notebook)
                Circle().fill(NB.dim).frame(width: 7, height: 7)
            }
            .font(.system(size: 12.5)).foregroundColor(NB.text)
            .padding(.horizontal, 14).frame(height: 32)
            .background(NB.bg)
            .overlay(Rectangle().fill(NB.active).frame(height: 2), alignment: .top)
            HStack(spacing: 8) {
                Image(systemName: "book.closed").font(.system(size: 11))
                Text("cohort_retention.ipynb")
            }
            .font(.system(size: 12.5)).foregroundColor(NB.dim).padding(.horizontal, 14)
            Spacer()
        }
        .frame(height: 32).background(NB.chrome)
    }

    private var toolbar: some View {
        HStack(spacing: 16) {
            ForEach(["square.and.arrow.down", "plus", "scissors", "doc.on.doc", "doc.on.clipboard", "play.fill", "stop.fill",
                     "arrow.clockwise", "forward.end.fill"], id: \.self) { Image(systemName: $0) }
            Text("Code").padding(.horizontal, 8).padding(.vertical, 2).overlay(RoundedRectangle(cornerRadius: 3).stroke(NB.border))
            Spacer()
            Text("Python 3 (ipykernel)")
            Image(systemName: sim.busy ? "circle.fill" : "circle").foregroundColor(sim.busy ? NB.dim : NB.dim.opacity(0.7))
        }
        .font(.system(size: 12.5)).foregroundColor(NB.dim)
        .padding(.horizontal, 14).frame(height: 34)
        .overlay(Rectangle().fill(NB.border).frame(height: 1), alignment: .bottom)
    }

    private var cellsArea: some View {
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 14) {
                ForEach(sim.cells) { cell in cellView(cell, width: geo.size.width) }
            }
            .padding(.vertical, 16)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .bottomLeading)
        }
        .clipped()
    }

    private func cellView(_ cell: NotebookSim.Cell, width: CGFloat) -> some View {
        let active = cell.id == sim.activeID
        let prompt = cell.running ? "[*]:" : cell.exec.map { "[\($0)]:" } ?? "[ ]:"
        let lines = cell.code.components(separatedBy: "\n")
        let typing = active && sim.typist.isActive
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Text(prompt).font(NB.mono).foregroundColor(NB.inPrompt).frame(width: 64, alignment: .trailing).padding(.top, 6)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, l in
                        codeLine(l, cursor: typing && i == lines.count - 1)
                            .lineLimit(1).fixedSize(horizontal: true, vertical: false).frame(height: 19, alignment: .leading)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(NB.cell)
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(active ? NB.active.opacity(0.6) : NB.border))
                .clipped()
            }
            if !cell.stdout.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(cell.stdout.enumerated()), id: \.offset) { _, l in
                        Text(l.isEmpty ? " " : l).font(NB.mono).foregroundColor(NB.text).frame(height: 18, alignment: .leading)
                    }
                }
                .padding(.leading, 82)
            }
            outputView(cell)
        }
        .padding(.trailing, 24)
        .overlay(Rectangle().fill(active ? NB.active : .clear).frame(width: 3), alignment: .leading)
    }

    private func codeLine(_ l: String, cursor: Bool) -> Text {
        var s = Highlighter.line(l, lang: .python, palette: .light)
        if cursor {
            var c = AttributedString("▏")
            c.foregroundColor = NB.text
            s.append(c)
        }
        return Text(s).font(NB.mono)
    }

    @ViewBuilder
    private func outputView(_ cell: NotebookSim.Cell) -> some View {
        switch cell.output {
        case .none: EmptyView()
        case let .text(lines):
            VStack(alignment: .leading, spacing: 0) { ForEach(Array(lines.enumerated()), id: \.offset) { Text($0.element).font(NB.mono) } }
                .padding(.leading, 82)
        case let .table(columns, index, rows):
            HStack(alignment: .top, spacing: 8) {
                Text(cell.exec.map { "[\($0)]:" } ?? "").font(NB.mono).foregroundColor(NB.outPrompt).frame(width: 64, alignment: .trailing)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 0) {
                        Text("").frame(width: 140, alignment: .leading)
                        ForEach(columns, id: \.self) { Text($0).bold().frame(width: 104, alignment: .trailing) }
                    }
                    .frame(height: 26)
                    .overlay(Rectangle().fill(Color.black.opacity(0.6)).frame(height: 1), alignment: .bottom)
                    ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                        HStack(spacing: 0) {
                            Text(index[i]).bold().lineLimit(1).frame(width: 140, alignment: .leading)
                            ForEach(Array(r.enumerated()), id: \.offset) { Text($0.element).frame(width: 104, alignment: .trailing) }
                        }
                        .frame(height: 25)
                        .background(i % 2 == 0 ? Color(hex: 0xF5F5F5) : Color.clear)
                    }
                }
                .font(.system(size: 12)).foregroundColor(NB.text)
                .padding(.leading, 10)
                Spacer(minLength: 0)
            }
        case let .lines(title, labels, series):
            chartWrap(cell) {
                Canvas { ctx, size in
                    let plot = CGRect(x: 64, y: 28, width: size.width - 150, height: size.height - 58)
                    frameAxes(ctx, plot, title: title, size: size)
                    let maxV = series.flatMap(\.values).max() ?? 1
                    for (si, s) in series.enumerated() {
                        var p = Path()
                        for (i, v) in s.values.enumerated() {
                            let c = CGPoint(x: plot.minX + plot.width * Double(i) / Double(s.values.count - 1), y: plot.maxY - plot.height * v / (maxV * 1.08))
                            i == 0 ? p.move(to: c) : p.addLine(to: c)
                        }
                        ctx.stroke(p, with: .color(NB.mpl[si]), lineWidth: 2)
                        ctx.stroke(Path { $0.move(to: CGPoint(x: plot.maxX + 14, y: plot.minY + 10 + Double(si) * 18)); $0.addLine(to: CGPoint(x: plot.maxX + 34, y: plot.minY + 10 + Double(si) * 18)) },
                                   with: .color(NB.mpl[si]), lineWidth: 2)
                        ctx.draw(Text(s.name).font(.system(size: 11)), at: CGPoint(x: plot.maxX + 40, y: plot.minY + 10 + Double(si) * 18), anchor: .leading)
                    }
                    for (i, l) in labels.enumerated() {
                        ctx.draw(Text(l).font(.system(size: 10.5)), at: CGPoint(x: plot.minX + plot.width * Double(i) / Double(labels.count - 1), y: plot.maxY + 12))
                    }
                    for k in 0...4 {
                        let v = maxV * 1.08 * Double(k) / 4
                        ctx.draw(Text(String(format: "%.0fk", v / 1000)).font(.system(size: 10.5)), at: CGPoint(x: plot.minX - 8, y: plot.maxY - plot.height * Double(k) / 4), anchor: .trailing)
                    }
                    ctx.draw(Text("USD").font(.system(size: 11)), at: CGPoint(x: 14, y: plot.midY))
                }
                .frame(height: 280)
            }
        case let .histogram(title, values):
            chartWrap(cell) {
                Canvas { ctx, size in
                    let plot = CGRect(x: 56, y: 28, width: size.width - 80, height: size.height - 58)
                    frameAxes(ctx, plot, title: title, size: size)
                    let maxV = values.max() ?? 1
                    let w = plot.width / Double(values.count)
                    for (i, v) in values.enumerated() {
                        let h = plot.height * v / (maxV * 1.1)
                        ctx.fill(Path(CGRect(x: plot.minX + Double(i) * w + 0.5, y: plot.maxY - h, width: w - 1, height: h)), with: .color(NB.mpl[0]))
                    }
                    for k in stride(from: 0, through: 60, by: 10) {
                        ctx.draw(Text("\(k)").font(.system(size: 10.5)), at: CGPoint(x: plot.minX + plot.width * Double(k) / 60, y: plot.maxY + 12))
                    }
                }
                .frame(height: 240)
            }
        case let .hbars(title, labels, values):
            chartWrap(cell) {
                Canvas { ctx, size in
                    let plot = CGRect(x: 150, y: 28, width: min(560, size.width - 190), height: size.height - 50)
                    frameAxes(ctx, plot, title: title, size: size)
                    let maxV = values.max() ?? 1
                    let h = plot.height / Double(values.count)
                    for (i, v) in values.enumerated() {
                        let y = plot.minY + Double(i) * h
                        ctx.fill(Path(CGRect(x: plot.minX, y: y + h * 0.18, width: plot.width * v / (maxV * 1.1), height: h * 0.64)), with: .color(NB.mpl[0]))
                        ctx.draw(Text(labels[i]).font(.system(size: 11)), at: CGPoint(x: plot.minX - 8, y: y + h / 2), anchor: .trailing)
                    }
                }
                .frame(height: 250)
            }
        }
    }

    private func chartWrap<C: View>(_ cell: NotebookSim.Cell, @ViewBuilder _ content: () -> C) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("").frame(width: 64)
            content().frame(maxWidth: 900)
            Spacer(minLength: 0)
        }
    }

    private func frameAxes(_ ctx: GraphicsContext, _ plot: CGRect, title: String, size: CGSize) {
        ctx.stroke(Path(plot), with: .color(.black), lineWidth: 0.8)
        ctx.draw(Text(title).font(.system(size: 13)), at: CGPoint(x: plot.midX, y: 12))
    }

    private var statusBar: some View {
        HStack(spacing: 16) {
            Text("Simple")
            Image(systemName: "togglepower")
            Text("1  $_   3  ⚙")
            Text("Python 3 (ipykernel) | \(sim.busy ? "Busy" : "Idle")")
            Spacer()
            Text("Mode: \(sim.typist.isActive ? "Edit" : "Command")")
            Text("Ln \(max(1, sim.cells.last?.code.components(separatedBy: "\n").count ?? 1)), Col \((sim.cells.last?.code.components(separatedBy: "\n").last?.count ?? 0) + 1)")
            Text(sim.notebook)
        }
        .font(.system(size: 12)).foregroundColor(NB.dim)
        .padding(.horizontal, 12).frame(height: 24)
        .background(NB.chrome)
    }
}
