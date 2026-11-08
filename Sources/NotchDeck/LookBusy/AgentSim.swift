import Foundation

struct LogLine: Identifiable {
    enum Style { case tool, result, thinking, pass, fail, plain, dim }
    let id: Int
    let text: String
    let style: Style
}

struct TreeLine: Identifiable {
    let id: String
    let depth: Int
    let name: String
    let isDir: Bool
    let expanded: Bool
    let isCurrent: Bool
}

struct EditorRow: Identifiable {
    enum Kind { case normal, removed, added }
    let id: Int
    let number: Int?
    let text: String
    let kind: Kind
    let cursor: Bool
}

/// Simulates an AI coding agent: reads files, types out an edit, runs tests, fixes a failure, ticks todos.
final class AgentSim {
    let project: Project
    private var rng: SplitMix64

    private(set) var log: [LogLine] = []
    private var nextID = 0
    private(set) var prompt = ""
    private(set) var todos: [(text: String, done: Bool)] = []
    private var todoCursor = 0
    private(set) var elapsed: Double
    private(set) var tokens: Double

    private(set) var openFiles: [String] = []
    private(set) var edit: FileEdit?
    private var addedChars: [Character] = []
    private(set) var typed = 0
    private(set) var typing = false
    private var acc = 0.0, pause = 0.0, cps = 30.0
    private(set) var typo: Character?
    private var typoLeft = 0.0
    private(set) var tree: [TreeLine] = []

    private enum Step {
        case log(String, LogLine.Style, Double)
        case beginEdit(FileEdit)
        case finishEdit
        case todo
        case cycle
    }
    private var queue: [Step] = [.cycle]
    private var wait = 0.0
    private var lastFile = ""

    init(project: Project, seed: UInt64) {
        self.project = project
        rng = SplitMix64(state: seed)
        elapsed = 600 + Double(rng.int(0..<900))
        tokens = 12_000 + Double(rng.int(0..<20_000))
        newTask()
        buildTree(current: project.editable.first ?? "")
    }

    var currentFile: String { edit?.path ?? "" }

    // MARK: - task & cycle generation

    private func newTask() {
        var picks = project.editable.shuffledDeterministic(&rng)
        if picks.count < 3 { picks += project.editable + project.editable + ["src/main"] }
        let a = (picks[0] as NSString).lastPathComponent
        let b = (picks[1] as NSString).lastPathComponent
        let c = (picks[2] as NSString).lastPathComponent
        let prompts = [
            "Move every caller in \(project.name) to the new retry policy, delete the deprecated helpers, and keep the whole test suite green.",
            "Refactor the error handling in \(project.name) so failures are typed, logged once, and never swallowed. Run the tests after each change.",
            "Profile the hot paths in \(project.name), fix the obvious allocations and add regression tests for anything you touch.",
        ]
        prompt = rng.pick(prompts)
        todos = [
            ("Audit call sites in \(a)", false),
            ("Rewrite the core logic in \(b)", false),
            ("Update the callers in \(c)", false),
            ("Add tests for the new edge cases", false),
            ("Run the full test suite and fix failures", false),
        ]
        todoCursor = 0
    }

    private func enqueueCycle() {
        if todoCursor >= todos.count {
            append("⏺ All tasks complete. Starting the next one.", .result)
            newTask()
        }
        var file = rng.pick(project.editable.isEmpty ? ["src/main.ts"] : project.editable)
        if file == lastFile, project.editable.count > 1 { file = rng.pick(project.editable) }
        lastFile = file
        let e = CodeGen.make(path: file, lang: project.lang, rng: &rng)
        let other = (rng.pick(project.editable.isEmpty ? [file] : project.editable) as NSString).lastPathComponent
        let lines = e.context.count + e.removed.count + e.after.count + rng.int(40..<260)
        var steps: [Step] = [
            .log("⏺ Read(\(file))", .tool, 0.45),
            .log("  ⎿  Read \(lines) lines", .result, 0.9),
        ]
        if rng.chance(0.6) {
            steps += [
                .log("⏺ Search(pattern: \"\(e.symbol)\", path: \"\(topDir(file))\")", .tool, 0.5),
                .log("  ⎿  Found \(rng.int(2..<14)) files", .result, 0.8),
            ]
        }
        let thoughts = [
            "\(e.symbol) has no timeout, so one slow upstream call blocks the whole request. Adding an abort signal and a bounded retry.",
            "Callers of \(e.symbol) still expect the old signature. Updating it first, then fixing the call sites so the build stays green.",
            "This duplicates the logic in \(other). Pulling it into one place keeps both paths consistent.",
            "An empty batch reaches \(e.symbol) and divides by zero. Guarding that case and covering it with a test.",
            "Profiling shows \(e.symbol) allocates on every call. Reusing the buffer should remove most of that.",
        ]
        steps += [
            .log(rng.pick(thoughts), .thinking, 1.3),
            .log("⏺ Update(\(file))", .tool, 0.25),
            .beginEdit(e),
            .finishEdit,
        ]
        if rng.chance(0.65) { steps += testSteps(file: file, symbol: e.symbol) }
        steps += [.todo, .cycle]
        queue += steps
    }

    private func topDir(_ path: String) -> String {
        let parts = path.split(separator: "/")
        return parts.count > 1 ? String(parts[0]) : "."
    }

    private func testSteps(file: String, symbol: String) -> [Step] {
        let n = Names(path: file)
        let total = rng.int(120..<480)
        let fails = rng.chance(0.35)
        var s: [Step] = []
        let files = (0..<rng.int(3..<6)).map { _ in rng.pick(project.editable.isEmpty ? [file] : project.editable) }
        switch project.lang {
        case .typescript:
            s.append(.log("⏺ Bash(npm test -- --runInBand \(n.snake.replacingOccurrences(of: "_", with: "-")))", .tool, 0.9))
            for f in files { s.append(.log("  PASS  \(testPath(f)) (\(String(format: "%.1f", rng.range(0.2, 2.4))) s)", .pass, rng.range(0.15, 0.45))) }
            if fails {
                s += [
                    .log("  FAIL  \(testPath(file))", .fail, 0.3),
                    .log("    ● \(n.pascal) › retries once on 503", .fail, 0.2),
                    .log("      Expected: 2   Received: 1", .dim, 0.25),
                    .log("  Tests: 1 failed, \(total - 1) passed, \(total) total", .fail, 1.0),
                ]
            } else {
                s.append(.log("  Tests: \(total) passed, \(total) total", .pass, 0.8))
            }
        case .python:
            s.append(.log("⏺ Bash(pytest -q tests/ -k \(n.snake))", .tool, 0.9))
            var pct = 0
            for f in files {
                pct = min(100, pct + rng.int(12..<34))
                let dots = String(repeating: ".", count: rng.int(6..<24))
                s.append(.log("  \(testPath(f)) \(dots)  [\(String(format: "%3d", pct))%]", .pass, rng.range(0.2, 0.5)))
            }
            if fails {
                s += [
                    .log("  FAILED \(testPath(file))::test_\(n.snake)_empty_batch - AssertionError", .fail, 0.3),
                    .log("  ==== 1 failed, \(total - 1) passed in \(String(format: "%.2f", rng.range(4, 30)))s ====", .fail, 1.0),
                ]
            } else {
                s.append(.log("  ==== \(total) passed in \(String(format: "%.2f", rng.range(4, 30)))s ====", .pass, 0.8))
            }
        case .swift:
            s.append(.log("⏺ Bash(swift test --filter \(n.pascal)Tests)", .tool, 1.0))
            s.append(.log("  Building for debugging...", .dim, 0.9))
            s.append(.log("  Build complete! (\(String(format: "%.2f", rng.range(2, 9)))s)", .dim, 0.4))
            if fails {
                s += [
                    .log("  \(n.pascal)Tests.swift:41: error: XCTAssertEqual failed: (\"1\") is not equal to (\"2\")", .fail, 0.3),
                    .log("  Executed \(total) tests, with 1 failure (0 unexpected)", .fail, 1.0),
                ]
            } else {
                s.append(.log("  Executed \(total) tests, with 0 failures (0 unexpected)", .pass, 0.8))
            }
        case .go:
            s.append(.log("⏺ Bash(go test ./... -run \(n.pascal) -count=1)", .tool, 0.9))
            for f in files { s.append(.log("  ok   \(project.name)/\(topDir(f))\t\(String(format: "%.3f", rng.range(0.05, 1.8)))s", .pass, rng.range(0.15, 0.4))) }
            if fails {
                s += [
                    .log("  --- FAIL: Test\(n.pascal)Timeout (0.21s)", .fail, 0.25),
                    .log("  FAIL\t\(project.name)/\(topDir(file))", .fail, 1.0),
                ]
            } else {
                s.append(.log("  PASS", .pass, 0.8))
            }
        case .cpp:
            s.append(.log("⏺ Bash(cmake --build build -j && ctest --test-dir build -R \(n.snake))", .tool, 1.0))
            s.append(.log("  [100%] Built target \(n.snake)_tests", .dim, 0.6))
            for (i, f) in files.enumerated() {
                s.append(.log("  \(i + 1)/\(files.count) Test #\(i + 1): \(Names(path: f).snake) ....   Passed    \(String(format: "%.2f", rng.range(0.01, 0.6))) sec", .pass, rng.range(0.15, 0.4)))
            }
            if fails {
                s += [
                    .log("  \(files.count + 1)/\(files.count + 1) Test #\(files.count + 1): \(n.snake)_bounds ....***Failed", .fail, 0.3),
                    .log("  \(Int(100 * Double(files.count) / Double(files.count + 1)))% tests passed, 1 tests failed", .fail, 1.0),
                ]
            } else {
                s.append(.log("  100% tests passed, 0 tests failed out of \(files.count)", .pass, 0.8))
            }
        }
        if fails {
            s += [
                .log("The retry counter starts at 1, so the last attempt is skipped. Fixing the off-by-one in \(n.camel).", .thinking, 1.4),
                .log("⏺ Update(\(file))", .tool, 0.9),
                .log("  ⎿  Updated \(file) with 1 addition and 1 removal", .result, 0.8),
                .log("⏺ Bash(re-running the failing tests)", .tool, 1.4),
                .log("  ✓ \(total) passed, 0 failed", .pass, 0.9),
            ]
        }
        return s
    }

    private func testPath(_ f: String) -> String {
        let n = Names(path: f)
        switch project.lang {
        case .typescript: return "test/" + ((f as NSString).deletingPathExtension as NSString).lastPathComponent + ".test.ts"
        case .python: return "tests/test_\(n.snake).py"
        default: return f
        }
    }

    // MARK: - simulation

    func advance(_ dt: Double) {
        elapsed += dt
        tokens += dt * (typing ? 60 : 28) * rng.range(0.6, 1.4)
        if typing { advanceTyping(dt); return }
        wait -= dt
        while wait <= 0, !typing, !queue.isEmpty {
            switch queue.removeFirst() {
            case let .log(text, style, delay):
                append(text, style)
                wait += delay
            case let .beginEdit(e):
                startEdit(e)
            case .finishEdit:
                if let e = edit {
                    let a = e.added.count, r = e.removed.count
                    append("  ⎿  Updated \(e.path) with \(a) addition\(a == 1 ? "" : "s") and \(r) removal\(r == 1 ? "" : "s")", .result)
                }
                wait += 0.7
            case .todo:
                if todoCursor < todos.count { todos[todoCursor].done = true; todoCursor += 1 }
                wait += 0.3
            case .cycle:
                enqueueCycle()
            }
        }
    }

    /// Someone hit a key: make the code appear faster instead of reacting oddly.
    func boost() {
        if typing {
            typo = nil; typoLeft = 0; pause = 0
            for _ in 0..<4 where typed < addedChars.count {
                let ch = addedChars[typed]
                typed += 1
                if ch == "\n" { skipIndent() }
            }
            if typed >= addedChars.count { typing = false; wait = 0.3 }
        } else {
            wait = min(wait, 0.05)
        }
    }

    private func startEdit(_ e: FileEdit) {
        edit = e
        addedChars = Array(e.added.joined(separator: "\n"))
        typed = 0
        skipIndent()
        typing = true
        pause = 0.5
        cps = rng.range(24, 40)
        openFiles.removeAll { $0 == e.path }
        openFiles.insert(e.path, at: 0)
        if openFiles.count > 4 { openFiles.removeLast() }
        buildTree(current: e.path)
    }

    private func skipIndent() {
        while typed < addedChars.count && addedChars[typed] == " " { typed += 1 }
    }

    private func advanceTyping(_ dt: Double) {
        if typoLeft > 0 {
            typoLeft -= dt
            if typoLeft <= 0 { typo = nil; pause = 0.1 }
            return
        }
        if pause > 0 { pause -= dt; return }
        acc += dt * cps
        while acc >= 1 && typed < addedChars.count {
            acc -= 1
            let ch = addedChars[typed]
            typed += 1
            if ch == "\n" {
                skipIndent()
                pause = rng.range(0.05, 0.55)
                cps = rng.range(18, 44)
                acc = 0
                break
            }
            if ch != " " && rng.chance(0.012) {
                typo = Character(UnicodeScalar(UInt8(97 + rng.int(0..<26))))
                typoLeft = rng.range(0.12, 0.28)
                acc = 0
                break
            }
        }
        if typed >= addedChars.count {
            typing = false
            wait = 0.4
        }
    }

    private func append(_ text: String, _ style: LogLine.Style) {
        log.append(LogLine(id: nextID, text: text, style: style))
        nextID += 1
        if log.count > 300 { log.removeFirst(log.count - 300) }
    }

    // MARK: - view data

    func editorRows() -> (rows: [EditorRow], cursorRow: Int, column: Int) {
        guard let e = edit else { return ([], 0, 0) }
        var rows: [EditorRow] = []
        var number = 1
        var id = 0
        func add(_ text: String, _ kind: EditorRow.Kind, cursor: Bool = false) {
            rows.append(EditorRow(id: id, number: kind == .removed ? nil : number, text: text, kind: kind, cursor: cursor))
            if kind != .removed { number += 1 }
            id += 1
        }
        for l in e.context { add(l, .normal) }
        for l in e.removed { add(l, .removed) }
        var text = String(addedChars[0..<typed])
        if let t = typo { text.append(t) }
        let lines = text.components(separatedBy: "\n")
        var cursorRow = rows.count, column = 1
        for (i, l) in lines.enumerated() {
            let last = i == lines.count - 1
            if last { cursorRow = rows.count; column = l.count + 1 }
            add(l, .added, cursor: last && typing)
        }
        if !typing { for l in e.after { add(l, .normal) } }
        return (rows, cursorRow, column)
    }

    private func buildTree(current: String) {
        final class Node {
            var children: [String: Node] = [:]
            var isFile = false
        }
        let root = Node()
        for f in project.files {
            var n = root
            let parts = f.split(separator: "/").map(String.init)
            for (i, p) in parts.enumerated() {
                let child = n.children[p] ?? Node()
                if i == parts.count - 1 { child.isFile = true }
                n.children[p] = child
                n = child
            }
        }
        var lines: [TreeLine] = []
        func walk(_ n: Node, _ prefix: String, _ depth: Int) {
            let sorted = n.children.sorted { a, b in
                let ad = !a.value.isFile, bd = !b.value.isFile
                return ad != bd ? ad : a.key.lowercased() < b.key.lowercased()
            }
            for (name, child) in sorted {
                let path = prefix.isEmpty ? name : prefix + "/" + name
                let isDir = !child.isFile
                let expanded = isDir && (current.hasPrefix(path + "/") || (depth == 0 && lines.count < 6))
                lines.append(TreeLine(id: path, depth: depth, name: name, isDir: isDir, expanded: expanded, isCurrent: path == current))
                if lines.count > 60 { return }
                if expanded { walk(child, path, depth + 1) }
            }
        }
        walk(root, "", 0)
        tree = lines
    }
}

extension Array {
    func shuffledDeterministic(_ rng: inout SplitMix64) -> [Element] {
        var a = self
        if a.count < 2 { return a }
        for i in stride(from: a.count - 1, to: 0, by: -1) { a.swapAt(i, rng.int(0..<(i + 1))) }
        return a
    }
}
