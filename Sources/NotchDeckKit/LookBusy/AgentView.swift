import SwiftUI

private enum IDE {
    static let bg = Color(hex: 0x1E1E1E)
    static let sidebar = Color(hex: 0x181818)
    static let activity = Color(hex: 0x141414)
    static let tabBar = Color(hex: 0x181818)
    static let tabActive = Color(hex: 0x1E1E1E)
    static let border = Color(hex: 0x2B2B2B)
    static let gutter = Color(hex: 0x6E7681)
    static let text = Color(hex: 0xCCCCCC)
    static let dim = Color(hex: 0x8B8B8B)
    static let selection = Color(hex: 0x37373D)
    static let added = Color(hex: 0x2EA043, alpha: 0.16)
    static let removed = Color(hex: 0xF85149, alpha: 0.16)
    static let status = Color(hex: 0x0078D4)
    static let term = Color(hex: 0x111111)
    static let accent = Color(hex: 0xD97757)
    static let mono = Font.system(size: 13, design: .monospaced)
    static let monoSmall = Font.system(size: 12.5, design: .monospaced)
    static let ui = Font.system(size: 12.5)
    static let line: CGFloat = 19
}

struct AgentView: View {
    let sim: AgentSim
    let t: Double

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    activityBar
                    sidebar.frame(width: 250)
                    Rectangle().fill(IDE.border).frame(width: 1)
                    editor
                    Rectangle().fill(IDE.border).frame(width: 1)
                    TerminalPane(sim: sim, t: t)
                        .frame(width: min(760, max(460, geo.size.width * 0.38)))
                }
                statusBar
            }
            .background(IDE.bg)
        }
    }

    private var activityBar: some View {
        VStack(spacing: 22) {
            ForEach(["doc.on.doc", "magnifyingglass", "arrow.triangle.branch", "play.circle", "square.grid.2x2"], id: \.self) { name in
                Image(systemName: name)
                    .font(.system(size: 19, weight: .light))
                    .foregroundColor(name == "doc.on.doc" ? .white : IDE.dim)
            }
            Spacer()
            Image(systemName: "person.crop.circle").font(.system(size: 19, weight: .light)).foregroundColor(IDE.dim)
            Image(systemName: "gearshape").font(.system(size: 19, weight: .light)).foregroundColor(IDE.dim)
        }
        .padding(.vertical, 16)
        .frame(width: 48)
        .frame(maxHeight: .infinity)
        .background(IDE.activity)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("EXPLORER").font(.system(size: 11, weight: .semibold)).foregroundColor(IDE.dim)
                .padding(.horizontal, 18).frame(height: 35)
            HStack(spacing: 4) {
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                Text(sim.project.name.uppercased()).font(.system(size: 11, weight: .bold))
            }
            .foregroundColor(IDE.text).padding(.horizontal, 8).frame(height: 22)
            ForEach(sim.tree) { line in
                HStack(spacing: 5) {
                    if line.isDir {
                        Image(systemName: line.expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold)).frame(width: 10)
                    } else {
                        Spacer().frame(width: 10)
                    }
                    Image(systemName: line.isDir ? (line.expanded ? "folder.fill" : "folder") : "doc.text")
                        .font(.system(size: 11)).foregroundColor(line.isDir ? Color(hex: 0xDCB67A) : Color(hex: 0x519ABA))
                    Text(line.name).font(IDE.ui).lineLimit(1)
                }
                .foregroundColor(line.isCurrent ? .white : IDE.text)
                .padding(.leading, CGFloat(14 + line.depth * 14))
                .frame(maxWidth: .infinity, minHeight: 22, maxHeight: 22, alignment: .leading)
                .background(line.isCurrent ? IDE.selection : Color.clear)
            }
            Spacer(minLength: 0)
            Text("TIMELINE").font(.system(size: 11, weight: .bold)).foregroundColor(IDE.dim)
                .padding(.horizontal, 14).frame(height: 26)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(IDE.sidebar)
        .clipped()
    }

    private var editor: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Array(sim.openFiles.enumerated()), id: \.element) { i, f in
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text").font(.system(size: 10)).foregroundColor(Color(hex: 0x519ABA))
                        Text((f as NSString).lastPathComponent).font(IDE.ui)
                        if i == 0 { Circle().fill(Color.white.opacity(0.8)).frame(width: 7, height: 7) }
                    }
                    .foregroundColor(i == 0 ? .white : IDE.dim)
                    .padding(.horizontal, 14)
                    .frame(height: 35)
                    .background(i == 0 ? IDE.tabActive : IDE.tabBar)
                    .overlay(Rectangle().fill(i == 0 ? IDE.status : .clear).frame(height: 1), alignment: .top)
                }
                Spacer(minLength: 0)
            }
            .frame(height: 35)
            .background(IDE.tabBar)
            Text(sim.currentFile.split(separator: "/").joined(separator: "  ›  "))
                .font(.system(size: 12)).foregroundColor(IDE.dim)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).frame(height: 24)
            GeometryReader { geo in
                codeArea(height: geo.size.height)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func codeArea(height: CGFloat) -> some View {
        let (rows, cursorRow, _) = sim.editorRows()
        let visible = max(1, Int(height / IDE.line) - 1)
        let first = max(0, min(rows.count - visible, cursorRow - visible + 10))
        let slice = rows.count > visible ? Array(rows[max(0, first)..<min(rows.count, max(0, first) + visible)]) : rows
        let blink = Int(t * 1.9) % 2 == 0 || sim.typing
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(slice) { row in
                HStack(spacing: 0) {
                    Text(row.number.map(String.init) ?? "")
                        .font(IDE.mono).foregroundColor(row.cursor ? IDE.text : IDE.gutter)
                        .frame(width: 52, alignment: .trailing)
                    Text(row.kind == .added ? "+" : row.kind == .removed ? "−" : " ")
                        .font(IDE.mono)
                        .foregroundColor(row.kind == .added ? Color(hex: 0x3FB950) : Color(hex: 0xF85149))
                        .frame(width: 22)
                    codeText(row, blink: blink)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 0)
                }
                .frame(height: IDE.line)
                .background(row.kind == .added ? IDE.added : row.kind == .removed ? IDE.removed : Color.clear)
            }
            Spacer(minLength: 0)
        }
        .clipped()
    }

    private func codeText(_ row: EditorRow, blink: Bool) -> Text {
        var s = Highlighter.line(row.text, lang: sim.project.lang)
        if row.kind == .removed { s.strikethroughStyle = .single; s.foregroundColor = Color(hex: 0xA0A0A0) }
        if row.cursor {
            var c = AttributedString("▏")
            c.foregroundColor = blink ? Color(hex: 0xAEAFAD) : .clear
            s.append(c)
        }
        return Text(s).font(IDE.mono)
    }

    private var cursorLine: Int {
        let (rows, cursorRow, _) = sim.editorRows()
        guard cursorRow < rows.count else { return 1 }
        return rows[cursorRow].number ?? cursorRow + 1
    }

    private var statusBar: some View {
        let (_, _, col) = sim.editorRows()
        return HStack(spacing: 16) {
            Label("main*", systemImage: "arrow.triangle.branch")
            Label("0", systemImage: "xmark.circle")
            Label("2", systemImage: "exclamationmark.triangle")
            Spacer()
            Text("Ln \(cursorLine), Col \(col)")
            Text("Spaces: \(sim.project.lang == .typescript ? 2 : 4)")
            Text("UTF-8")
            Text("LF")
            Text(sim.project.lang.display)
            Image(systemName: "bell")
        }
        .font(.system(size: 12))
        .foregroundColor(.white)
        .padding(.horizontal, 12)
        .frame(height: 24)
        .background(IDE.status)
    }
}

/// The agent's terminal: prompt, todos, streaming tool calls, a live status line.
private struct TerminalPane: View {
    let sim: AgentSim
    let t: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("TERMINAL").font(.system(size: 11, weight: .semibold)).foregroundColor(.white)
                Text("agent — ~/code/\(sim.project.name)").font(.system(size: 11)).foregroundColor(IDE.dim)
                Spacer()
                Image(systemName: "plus").font(.system(size: 11)).foregroundColor(IDE.dim)
                Image(systemName: "rectangle.split.2x1").font(.system(size: 11)).foregroundColor(IDE.dim)
            }
            .padding(.horizontal, 14).frame(height: 35)
            .background(IDE.tabBar)

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 8) {
                    Text(">").foregroundColor(IDE.dim)
                    Text(sim.prompt).foregroundColor(Color(hex: 0xE6E6E6)).fixedSize(horizontal: false, vertical: true)
                }
                .font(IDE.monoSmall)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(hex: 0x1B1B1B))
                .overlay(Rectangle().fill(Color(hex: 0x444444)).frame(width: 2), alignment: .leading)

                VStack(alignment: .leading, spacing: 3) {
                    Text("⏺ Update Todos").foregroundColor(.white).bold()
                    ForEach(Array(sim.todos.enumerated()), id: \.offset) { i, todo in
                        let current = !todo.done && (i == 0 || sim.todos[i - 1].done)
                        HStack(spacing: 6) {
                            Text(i == 0 ? "  ⎿" : "   ").foregroundColor(IDE.dim)
                            Text(todo.done ? "☒" : "☐")
                            Text(todo.text).strikethrough(todo.done)
                        }
                        .foregroundColor(todo.done ? IDE.dim : current ? Color(hex: 0xB4D7FF) : IDE.text)
                        .fontWeight(current ? .semibold : .regular)
                    }
                }
                .font(IDE.monoSmall)

                GeometryReader { geo in
                    let n = max(1, Int(geo.size.height / 19))
                    VStack(alignment: .leading, spacing: 0) {
                        Spacer(minLength: 0)
                        ForEach(sim.log.suffix(n)) { line in
                            logText(line).frame(height: 19, alignment: .leading)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }
                .clipped()

                statusLine
                inputBox
            }
            .padding(14)
        }
        .background(IDE.term)
    }

    private func logText(_ line: LogLine) -> some View {
        let text: Text
        switch line.style {
        case .tool:
            let body = String(line.text.dropFirst(2))
            text = Text("⏺ ").foregroundColor(Color(hex: 0x3FB950)) + Text(body).foregroundColor(.white).bold()
        case .result: text = Text(line.text).foregroundColor(IDE.dim)
        case .thinking: text = Text(line.text).foregroundColor(Color(hex: 0xB9B9B9)).italic()
        case .pass: text = Text(line.text).foregroundColor(Color(hex: 0x56D364))
        case .fail: text = Text(line.text).foregroundColor(Color(hex: 0xFF7B72))
        case .plain: text = Text(line.text).foregroundColor(IDE.text)
        case .dim: text = Text(line.text).foregroundColor(IDE.dim)
        }
        return text.font(IDE.monoSmall).lineLimit(1).truncationMode(.tail)
    }

    private var statusLine: some View {
        let frames = ["·", "✢", "✳", "✶", "✻", "✽", "✻", "✶", "✳", "✢"]
        let glyph = frames[Int(t * 8) % frames.count]
        let verbs = ["Working", "Refactoring", "Reasoning", "Wiring things up", "Running checks"]
        let verb = verbs[Int(sim.elapsed / 23) % verbs.count]
        return HStack(spacing: 6) {
            Text(glyph).foregroundColor(IDE.accent)
            Text("\(verb)…").foregroundColor(IDE.accent)
            Text("(\(duration(sim.elapsed)) · ↓ \(String(format: "%.1fk", sim.tokens / 1000)) tokens · esc to interrupt)")
                .foregroundColor(IDE.dim)
        }
        .font(IDE.monoSmall)
    }

    private var inputBox: some View {
        HStack(spacing: 8) {
            Text(">").foregroundColor(IDE.dim)
            Rectangle().fill(Int(t * 1.6) % 2 == 0 ? Color(hex: 0xBBBBBB) : .clear).frame(width: 8, height: 16)
            Spacer()
        }
        .font(IDE.monoSmall)
        .padding(.horizontal, 10).frame(height: 34)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(hex: 0x3A3A3A), lineWidth: 1))
        .overlay(
            Text("⏵⏵ auto-accept edits on").font(.system(size: 11, design: .monospaced)).foregroundColor(Color(hex: 0x9A7AD8))
                .padding(.trailing, 10),
            alignment: .trailing)
    }
}
