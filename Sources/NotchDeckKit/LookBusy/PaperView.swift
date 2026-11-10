import SwiftUI

private enum Tex {
    static let top = Color(hex: 0x2C3645)
    static let toolbar = Color(hex: 0xF4F5F7)
    static let border = Color(hex: 0xD9DDE3)
    static let side = Color(hex: 0xF7F8FA)
    static let editor = Color.white
    static let gutter = Color(hex: 0x9AA2AE)
    static let text = Color(hex: 0x1F2328)
    static let dim = Color(hex: 0x6B7280)
    static let command = Color(hex: 0x3B4BC8)
    static let math = Color(hex: 0x16803C)
    static let brace = Color(hex: 0x8250DF)
    static let comment = Color(hex: 0x8C959F)
    static let green = Color(hex: 0x138A36)
    static let pdfBg = Color(hex: 0x525A66)
    static let selected = Color(hex: 0xE3EAF5)
    static let mono = Font.system(size: 13.5, design: .monospaced)
    static let line: CGFloat = 21
}

struct PaperView: View {
    let sim: PaperSim
    let t: Double

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                topBar
                HStack(spacing: 0) {
                    fileTree.frame(width: 230)
                    Rectangle().fill(Tex.border).frame(width: 1)
                    editorPane.frame(width: (geo.size.width - 231) * 0.5)
                    Rectangle().fill(Tex.border).frame(width: 1)
                    pdfPane
                }
            }
            .background(Tex.editor)
        }
    }

    private var topBar: some View {
        HStack(spacing: 18) {
            Label("Menu", systemImage: "line.3.horizontal")
            Image(systemName: "house")
            Spacer()
            Text(sim.project).bold()
            Image(systemName: "pencil").font(.system(size: 11))
            Spacer()
            Label("Review", systemImage: "text.bubble")
            Label("History", systemImage: "clock.arrow.circlepath")
            Label("Share", systemImage: "person.2")
            Text("Submit").padding(.horizontal, 12).padding(.vertical, 5)
                .background(Color(hex: 0x3D4A5C)).clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .font(.system(size: 13))
        .foregroundColor(.white)
        .padding(.horizontal, 16)
        .frame(height: 42)
        .background(Tex.top)
    }

    private var fileTree: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "doc.badge.plus")
                Image(systemName: "folder.badge.plus")
                Image(systemName: "square.and.arrow.up")
                Spacer()
            }
            .font(.system(size: 13)).foregroundColor(Tex.dim)
            .padding(.horizontal, 14).frame(height: 38)
            ForEach(treeLines, id: \.path) { item in
                HStack(spacing: 6) {
                    Image(systemName: item.dir ? "folder" : item.path.hasSuffix(".pdf") ? "photo" : "doc.text")
                        .font(.system(size: 11)).foregroundColor(item.dir ? Color(hex: 0xB7862B) : Tex.dim)
                    Text(item.name).font(.system(size: 13)).foregroundColor(Tex.text)
                }
                .padding(.leading, CGFloat(14 + item.depth * 16))
                .frame(maxWidth: .infinity, minHeight: 26, maxHeight: 26, alignment: .leading)
                .background(item.path == sim.file ? Tex.selected : Color.clear)
            }
            Spacer()
            VStack(alignment: .leading, spacing: 6) {
                Text("File outline").font(.system(size: 12, weight: .semibold)).foregroundColor(Tex.dim)
                ForEach(outline, id: \.self) { Text($0).font(.system(size: 12)).foregroundColor(Tex.text).lineLimit(1) }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(Rectangle().fill(Tex.border).frame(height: 1), alignment: .top)
        }
        .background(Tex.side)
    }

    private var treeLines: [(path: String, name: String, depth: Int, dir: Bool)] {
        var out: [(String, String, Int, Bool)] = []
        var seen = Set<String>()
        for f in sim.files {
            let parts = f.split(separator: "/").map(String.init)
            if parts.count > 1, !seen.contains(parts[0]) {
                seen.insert(parts[0])
                out.append((parts[0], parts[0], 0, true))
            }
            out.append((f, parts.last!, parts.count - 1, false))
        }
        return out.map { (path: $0.0, name: $0.1, depth: $0.2, dir: $0.3) }
    }

    private var outline: [String] {
        sim.written.filter { $0.kind == .heading }.suffix(6).map { "\($0.label)  \($0.rendered)" }
    }

    private var editorPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("Code Editor").padding(.horizontal, 12).frame(height: 26)
                    .background(Color.white).overlay(RoundedRectangle(cornerRadius: 4).stroke(Tex.border))
                Text("Visual Editor").foregroundColor(Tex.dim).padding(.horizontal, 12)
                Spacer()
                HStack(spacing: 14) {
                    Text("B").bold(); Text("I").italic()
                    Image(systemName: "function"); Image(systemName: "link"); Image(systemName: "list.bullet")
                    Image(systemName: "tablecells"); Image(systemName: "photo")
                }
                .foregroundColor(Tex.dim)
            }
            .font(.system(size: 12.5))
            .padding(.horizontal, 12).frame(height: 40)
            .background(Tex.toolbar)
            .overlay(Rectangle().fill(Tex.border).frame(height: 1), alignment: .bottom)
            GeometryReader { geo in code(height: geo.size.height, width: geo.size.width) }
        }
    }

    private func code(height: CGFloat, width: CGFloat) -> some View {
        // Soft-wrap long LaTeX lines the way the editor would.
        let cols = max(20, Int((width - 70) / 8.2))
        let (raw, typingFrom) = sim.sourceLines()
        var rows: [(num: Int?, text: String, typing: Bool)] = []
        for (i, l) in raw.enumerated() {
            let pieces = wrap(l, cols)
            for (j, p) in pieces.enumerated() { rows.append((j == 0 ? i + 1 : nil, p, typingFrom.map { i >= $0 } ?? false)) }
        }
        let visible = max(1, Int(height / Tex.line) - 1)
        let tail = Array(rows.suffix(visible))
        let blink = Int(t * 1.9) % 2 == 0 || sim.typist.isActive
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(tail.enumerated()), id: \.offset) { idx, row in
                HStack(spacing: 0) {
                    Text(row.num.map(String.init) ?? "").font(Tex.mono).foregroundColor(Tex.gutter)
                        .frame(width: 44, alignment: .trailing)
                    Spacer().frame(width: 16)
                    latex(row.text, cursor: idx == tail.count - 1 && sim.typist.isActive && blink)
                    Spacer(minLength: 0)
                }
                .frame(height: Tex.line)
                .background(row.typing && idx == tail.count - 1 ? Color(hex: 0xF3F6FB) : Color.clear)
            }
            Spacer(minLength: 0)
        }
        .clipped()
    }

    private func wrap(_ s: String, _ n: Int) -> [String] {
        if s.count <= n { return [s] }
        var out: [String] = [], line = ""
        for word in s.split(separator: " ", omittingEmptySubsequences: false) {
            if line.count + word.count + 1 > n, !line.isEmpty { out.append(line); line = "" }
            line += line.isEmpty ? String(word) : " " + word
        }
        if !line.isEmpty || out.isEmpty { out.append(line) }
        return out
    }

    private func latex(_ s: String, cursor: Bool) -> Text {
        var out = AttributedString()
        let chars = Array(s)
        var i = 0
        var inMath = false
        func emit(_ str: String, _ c: Color) { var a = AttributedString(str); a.foregroundColor = c; out.append(a) }
        while i < chars.count {
            let ch = chars[i]
            if ch == "%" && (i == 0 || chars[i - 1] != "\\") { emit(String(chars[i...]), Tex.comment); break }
            if ch == "$" { inMath.toggle(); emit("$", Tex.math); i += 1; continue }
            if ch == "\\" {
                var j = i + 1
                while j < chars.count && chars[j].isLetter { j += 1 }
                if j == i + 1 && j < chars.count { j += 1 }
                emit(String(chars[i..<j]), inMath ? Tex.math : Tex.command)
                i = j
                continue
            }
            if ch == "{" || ch == "}" || ch == "[" || ch == "]" { emit(String(ch), inMath ? Tex.math : Tex.brace); i += 1; continue }
            var j = i
            while j < chars.count && !"%$\\{}[]".contains(chars[j]) { j += 1 }
            emit(String(chars[i..<j]), inMath ? Tex.math : Tex.text)
            i = j
        }
        if cursor { emit("▏", Color(hex: 0x1F2328)) }
        return Text(out).font(Tex.mono)
    }

    private var pdfPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    if sim.compiling {
                        Image(systemName: "arrow.triangle.2.circlepath").rotationEffect(.degrees(t * 360))
                        Text("Compiling…")
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text("Recompile")
                    }
                    Image(systemName: "chevron.down").font(.system(size: 9))
                }
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundColor(.white).padding(.horizontal, 12).frame(height: 28)
                .background(Tex.green).clipShape(RoundedRectangle(cornerRadius: 5))
                HStack(spacing: 4) {
                    Image(systemName: "doc.text.magnifyingglass")
                    Text("\(sim.warnings)").font(.system(size: 11, weight: .bold)).foregroundColor(.white)
                        .padding(.horizontal, 5).background(Color(hex: 0xD97706)).clipShape(Capsule())
                }
                Image(systemName: "arrow.down.to.line")
                Spacer()
                Text(sim.compiling ? "Compiling…" : "Compiled \(Int(sim.sinceCompile))s ago")
                    .foregroundColor(Tex.dim)
                Text("Words: \(grouped(sim.words))").foregroundColor(Tex.dim)
                Text("\(min(sim.pages, 4 + sim.compiled.count / 4)) / \(sim.pages)")
                Text("100%")
            }
            .font(.system(size: 12.5))
            .foregroundColor(Tex.text)
            .padding(.horizontal, 12).frame(height: 40)
            .background(Tex.toolbar)
            .overlay(Rectangle().fill(Tex.border).frame(height: 1), alignment: .bottom)
            GeometryReader { geo in
                let w = min(geo.size.width - 60, 700)
                ZStack(alignment: .top) {
                    Tex.pdfBg
                    page(width: w)
                        .frame(width: w, height: w * 1.414, alignment: .top)
                        .background(Color.white)
                        .shadow(color: .black.opacity(0.35), radius: 10, y: 3)
                        .padding(.top, 24)
                        .opacity(sim.compiling ? 0.82 : 1)
                }
                .clipped()
            }
        }
    }

    private func page(width w: CGFloat) -> some View {
        let s = w / 700
        let blocks = Array(sim.compiled.suffix(6))
        return VStack(alignment: .leading, spacing: 12 * s) {
            HStack {
                Text("Under review as a conference paper").italic()
                Spacer()
                Text(sim.title).italic().lineLimit(1)
            }
            .font(.system(size: 9.5 * s, design: .serif)).foregroundColor(Color(hex: 0x555555))
            Rectangle().fill(Color(hex: 0xBBBBBB)).frame(height: 0.6)
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in
                switch b.kind {
                case .heading:
                    Text("\(b.label)   \(b.rendered)").font(.system(size: (b.label.contains(".") ? 14 : 16) * s, weight: .bold, design: .serif))
                        .padding(.top, 6 * s)
                case .paragraph:
                    paragraph(b.rendered, scale: s)
                case .equation:
                    HStack {
                        Spacer()
                        Text(b.rendered).font(.system(size: 15 * s, design: .serif)).italic()
                        Spacer()
                        Text(b.label).font(.system(size: 13 * s, design: .serif))
                    }
                    .padding(.vertical, 4 * s)
                case .figure:
                    VStack(spacing: 6 * s) {
                        LatencyFigure().frame(height: 170 * s)
                        (Text("\(b.label): ").bold() + Text(b.rendered))
                            .font(.system(size: 11.5 * s, design: .serif))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 4 * s)
                }
            }
            Spacer(minLength: 0)
            HStack { Spacer(); Text("\(min(sim.pages, 4 + sim.compiled.count / 4))").font(.system(size: 11 * s, design: .serif)); Spacer() }
        }
        .foregroundColor(.black)
        .padding(.horizontal, 64 * s)
        .padding(.vertical, 44 * s)
    }

    private func paragraph(_ s: String, scale: CGFloat) -> some View {
        // Bold run-in heading like "Overview." when present.
        let text: Text
        if let dot = s.firstIndex(of: "."), s.distance(from: s.startIndex, to: dot) < 14, s.first?.isUppercase == true {
            text = Text(String(s[...dot])).bold() + Text(String(s[s.index(after: dot)...]))
        } else {
            text = Text(s)
        }
        return text.font(.system(size: 13 * scale, design: .serif))
            .lineSpacing(3 * scale)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Small matplotlib-style figure for the PDF: latency vs context length.
private struct LatencyFigure: View {
    var body: some View {
        Canvas { ctx, size in
            let plot = CGRect(x: 44, y: 8, width: size.width - 60, height: size.height - 34)
            ctx.stroke(Path(plot), with: .color(.black), lineWidth: 0.8)
            let xs = [1.0, 2, 4, 8, 16, 32, 64]
            func pt(_ i: Int, _ v: Double) -> CGPoint {
                CGPoint(x: plot.minX + plot.width * Double(i) / Double(xs.count - 1), y: plot.maxY - plot.height * v / 4200)
            }
            var dense = Path(), ours = Path()
            for (i, x) in xs.enumerated() {
                let d = 0.95 * x * x + 6 * x, o = 9 * x + 22
                i == 0 ? dense.move(to: pt(i, d)) : dense.addLine(to: pt(i, d))
                i == 0 ? ours.move(to: pt(i, o)) : ours.addLine(to: pt(i, o))
                ctx.draw(Text(x >= 1 ? "\(Int(x))k" : "").font(.system(size: 9, design: .serif)), at: CGPoint(x: pt(i, 0).x, y: plot.maxY + 10))
            }
            ctx.stroke(dense, with: .color(Color(hex: 0xD62728)), lineWidth: 1.6)
            ctx.stroke(ours, with: .color(Color(hex: 0x1F77B4)), lineWidth: 1.6)
            for (i, x) in xs.enumerated() {
                let o = pt(i, 9 * x + 22)
                ctx.fill(Path(ellipseIn: CGRect(x: o.x - 2.5, y: o.y - 2.5, width: 5, height: 5)), with: .color(Color(hex: 0x1F77B4)))
            }
            for v in [0.0, 1000, 2000, 3000, 4000] {
                ctx.draw(Text("\(Int(v))").font(.system(size: 8.5, design: .serif)), at: CGPoint(x: plot.minX - 16, y: plot.maxY - plot.height * v / 4200))
            }
            ctx.draw(Text("context length (tokens)").font(.system(size: 9, design: .serif)), at: CGPoint(x: plot.midX, y: size.height - 4))
            ctx.draw(Text("dense attention").font(.system(size: 9, design: .serif)).foregroundColor(Color(hex: 0xD62728)),
                     at: CGPoint(x: plot.minX + 12, y: plot.minY + 12), anchor: .leading)
            ctx.draw(Text("routing (ours)").font(.system(size: 9, design: .serif)).foregroundColor(Color(hex: 0x1F77B4)),
                     at: CGPoint(x: plot.minX + 12, y: plot.minY + 26), anchor: .leading)
        }
    }
}
