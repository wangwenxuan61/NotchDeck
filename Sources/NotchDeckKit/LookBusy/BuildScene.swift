import SwiftUI

/// 编译和测试：按项目的语言滚动编译日志，接着一项项跑测试，跑完等一会儿当作改了文件再增量编译一次。
final class BuildSim: BusySim {
    enum Phase: Equatable { case compiling, linking, testing, done }
    struct Line { let text: String; let kind: Kind; enum Kind { case plain, dim, pass, warn, info, success } }

    let project: Project
    private var rng: SplitMix64
    private(set) var phase = Phase.compiling
    private(set) var lines: [Line] = []
    private(set) var compileTotal = 0
    private(set) var compiled = 0
    private(set) var testTotal = 0
    private(set) var passed = 0
    private(set) var skipped = 0
    private(set) var phaseTime = 0.0
    private(set) var buildTime = 0.0
    private(set) var buildNumber: Int
    private(set) var cores: [Double] = Array(repeating: 10, count: 10)
    private(set) var history: [(number: Int, seconds: Double, tests: Int)] = []
    private(set) var cacheHit = 0.0
    private var acc = 0.0
    private var pause = 0.0
    private var incremental = false

    private static let behaviors = [
        "handles empty input", "retries on timeout", "rejects expired token", "keeps insertion order",
        "rolls back on error", "parses headers", "caches repeated lookups", "respects rate limit",
        "serializes round trip", "returns 404 for missing id", "merges partial updates", "times out slow upstream",
    ]

    init(project: Project, seed: UInt64) {
        self.project = project
        rng = SplitMix64(state: seed ^ 0xB01D_C0DE)
        buildNumber = 1200 + rng.int(0..<400)
        for i in 0..<3 {
            history.append((buildNumber - 3 + i, rng.range(38, 95), rng.int(380..<520)))
        }
        startBuild()
    }

    var files: [String] { project.editable.isEmpty ? project.files : project.editable }

    /// 完整编译时除了项目自己的文件，还有依赖库的文件，免得项目文件少时一眼看出在重复。
    private lazy var units: [String] = {
        let packages: [String], stems: [String], pattern: (String, String) -> String
        switch project.lang {
        case .typescript:
            packages = ["zod", "fastify", "pino", "ioredis", "drizzle-orm", "undici", "jose", "stripe", "date-fns", "ws"]
            stems = ["index", "types", "utils", "parser", "errors", "client", "stream", "helpers"]
            pattern = { "node_modules/\($0)/dist/\($1).js" }
        case .python:
            packages = ["pydantic", "sqlalchemy", "httpx", "numpy", "fastapi", "starlette", "anyio", "click"]
            stems = ["main", "types", "utils", "_compat", "errors", "fields", "core", "base"]
            pattern = { ".venv/lib/python3.12/site-packages/\($0)/\($1).py" }
        case .swift:
            packages = ["NIOCore", "NIOPosix", "Logging", "DequeModule", "AsyncHTTPClient", "Crypto", "NIOHTTP1", "Atomics"]
            stems = ["ByteBuffer", "Channel", "EventLoop", "Utilities", "Errors", "Handler", "Pool", "Codec"]
            pattern = { ".build/checkouts/deps/Sources/\($0)/\($1).swift" }
        case .go:
            packages = ["github.com/jackc/pgx/v5", "go.uber.org/zap", "github.com/redis/go-redis/v9", "google.golang.org/grpc", "golang.org/x/sync"]
            stems = ["internal/pool", "internal/proto", "codes", "status", "errgroup", "zapcore", "pgconn", "metadata"]
            pattern = { "\($0)/\($1)" }
        case .cpp:
            packages = ["abseil", "fmt", "spdlog", "protobuf", "grpc", "re2", "zlib"]
            stems = ["format", "str_cat", "async", "message", "call", "parser", "inflate", "arena"]
            pattern = { "third_party/\($0)/src/\($1).cc" }
        }
        var deps: [String] = []
        for stem in stems { for package in packages { deps.append(pattern(package, stem)) } }
        var all: [String] = []
        var d = 0
        for (i, file) in Array(repeating: files, count: 3).joined().enumerated() {
            all.append(file)
            for _ in 0..<(i % 3 + 2) where d < deps.count { all.append(deps[d]); d += 1 }
        }
        return all + deps.dropFirst(d)
    }()

    private func startBuild() {
        phase = .compiling
        phaseTime = 0
        buildTime = 0
        compiled = 0
        passed = 0
        skipped = 0
        compileTotal = incremental ? min(files.count, rng.int(3..<12)) : rng.int(220..<420)
        testTotal = incremental ? rng.int(60..<140) : rng.int(380..<560)
        cacheHit = incremental ? rng.range(88, 97) : rng.range(42, 71)
        add(command, .info)
    }

    private var command: String {
        switch project.lang {
        case .typescript: return "$ npm run build && npx vitest run"
        case .python: return "$ mypy src && pytest -q -n auto"
        case .swift: return "$ swift build && swift test --parallel"
        case .go: return "$ go build ./... && go test ./..."
        case .cpp: return "$ cmake --build build -j10 && ctest --test-dir build -j10"
        }
    }

    func advance(_ dt: Double) {
        phaseTime += dt
        buildTime += dt
        updateCores(dt)
        if pause > 0 { pause -= dt; return }
        switch phase {
        case .compiling:
            emit(dt, rate: 26) {
                compiled += 1
                add(compileLine(compiled), .plain)
                if rng.chance(0.015) { add(warningLine(), .warn) }
                if compiled >= compileTotal {
                    phase = .linking
                    phaseTime = 0
                    add(linkLine, .dim)
                    pause = rng.range(1.2, 2.2)
                }
            }
        case .linking:
            phase = .testing
            phaseTime = 0
            add(testHeader, .info)
        case .testing:
            emit(dt, rate: 17) {
                if rng.chance(0.03) { skipped += 1 } else { passed += 1 }
                add(testLine(passed + skipped), .pass)
                if passed + skipped >= testTotal {
                    phase = .done
                    phaseTime = 0
                    summary().forEach { add($0, .success) }
                    history.append((buildNumber, buildTime, testTotal))
                    if history.count > 5 { history.removeFirst() }
                    pause = rng.range(3, 6)
                }
            }
        case .done:
            incremental = true
            buildNumber += 1
            add("", .plain)
            add("[watch] change detected in \(rng.pick(files)) — rebuilding", .dim)
            startBuild()
        }
    }

    func boost() { acc += 4 }

    private func emit(_ dt: Double, rate: Double, _ line: () -> Void) {
        acc += dt * rate * rng.range(0.4, 1.6)
        while acc >= 1 && pause <= 0 {
            acc -= 1
            line()
            if phase != .compiling && phase != .testing { break }
        }
    }

    private func updateCores(_ dt: Double) {
        let busy = phase == .compiling || phase == .testing
        for i in cores.indices {
            let target = busy ? rng.range(72, 100) : rng.range(3, 14)
            cores[i] += (target - cores[i]) * min(1, dt * 4)
        }
    }

    private func add(_ text: String, _ kind: Line.Kind) {
        lines.append(Line(text: text, kind: kind))
        if lines.count > 300 { lines.removeFirst(lines.count - 300) }
    }

    // MARK: - 各语言的日志格式

    private func compileLine(_ i: Int) -> String {
        let file = incremental ? files[(i * 7 + buildNumber) % max(files.count, 1)] : units[(i * 7) % units.count]
        let names = Names(path: file)
        let module = (file as NSString).pathComponents.dropLast().last ?? project.name
        switch project.lang {
        case .typescript: return "transforming (\(i)) \(file)"
        case .python: return "Checking \(file) … ok"
        case .swift: return "[\(i)/\(compileTotal)] Compiling \(module.capitalized) \(names.pascal).swift"
        case .go: return "compile \(project.name)/\((file as NSString).deletingLastPathComponent)"
        case .cpp: return "[\(i)/\(compileTotal)] Building CXX object src/CMakeFiles/\(module).dir/\(names.snake).cpp.o"
        }
    }

    private func warningLine() -> String {
        let names = Names(path: rng.pick(files))
        switch project.lang {
        case .typescript: return "(!) \(names.camel) is imported but never used"
        case .python: return "note: \(names.snake).py:\(rng.int(10..<300)): unused \"type: ignore\" comment"
        case .swift: return "warning: initialization of immutable value '\(names.camel)' was never used"
        case .go: return "vet: \(names.snake).go:\(rng.int(10..<300)): result of fmt.Sprintf call not used"
        case .cpp: return "warning: unused variable '\(names.camel)' [-Wunused-variable]"
        }
    }

    private var linkLine: String {
        switch project.lang {
        case .typescript: return "rendering chunks… computing gzip size… dist/index.js  \(rng.int(300..<900)).\(rng.int(10..<99)) kB"
        case .python: return "Success: no issues found in \(compileTotal) source files"
        case .swift: return "[\(compileTotal)/\(compileTotal)] Linking \(project.name)"
        case .go: return "link \(project.name)/cmd/server"
        case .cpp: return "[\(compileTotal)/\(compileTotal)] Linking CXX executable bin/\(project.name)"
        }
    }

    private var testHeader: String {
        switch project.lang {
        case .typescript: return " RUN  v3.2.4 \(project.name)"
        case .python: return "============ test session starts ============ \(testTotal) items, 10 workers"
        case .swift: return "◇ Test run started."
        case .go: return "=== RUN   (\(testTotal) tests)"
        case .cpp: return "Test project build · \(testTotal) tests"
        }
    }

    private func testLine(_ i: Int) -> String {
        let file = files[(i * 5) % max(files.count, 1)]
        let names = Names(path: file)
        let behavior = Self.behaviors[(i * 3) % Self.behaviors.count]
        let ms = rng.int(1..<90)
        switch project.lang {
        case .typescript: return " ✓ test/\(names.camel).test.ts > \(names.pascal) > \(behavior) \(ms)ms"
        case .python:
            let percent = min(100, i * 100 / max(testTotal, 1))
            return "tests/test_\(names.snake).py::test_\(behavior.replacingOccurrences(of: " ", with: "_")) PASSED [\(String(format: "%3d", percent))%]"
        case .swift: return "✔ Test \(names.camel)\(behavior.split(separator: " ").map { $0.capitalized }.joined())() passed after 0.0\(String(format: "%02d", ms)) seconds."
        case .go: return "--- PASS: Test\(names.pascal)\(behavior.split(separator: " ").map { $0.capitalized }.joined()) (0.\(String(format: "%02d", ms))s)"
        case .cpp: return "\(String(format: "%3d", i))/\(testTotal) Test #\(i): \(names.snake)_\(behavior.replacingOccurrences(of: " ", with: "_")) ....   Passed    0.\(String(format: "%02d", ms)) sec"
        }
    }

    private func summary() -> [String] {
        let seconds = String(format: "%.2f", buildTime)
        switch project.lang {
        case .typescript: return [" Test Files  \(testTotal / 9) passed", "      Tests  \(passed) passed | \(skipped) skipped", "   Duration  \(seconds)s"]
        case .python: return ["====== \(passed) passed, \(skipped) skipped in \(seconds)s ======"]
        case .swift: return ["✔ Test run with \(testTotal) tests passed after \(seconds) seconds.", "Build complete!"]
        case .go: return ["ok  \t\(project.name)/...\t\(seconds)s", "PASS"]
        case .cpp: return ["100% tests passed, 0 tests failed out of \(testTotal)", "Total Test time (real) = \(seconds) sec"]
        }
    }
}

private enum Term {
    static let bg = Color(hex: 0x15171C)
    static let side = Color(hex: 0x1C1F26)
    static let border = Color(hex: 0x2B2F38)
    static let text = Color(hex: 0xD3D7DE)
    static let dim = Color(hex: 0x7D8590)
    static let green = Color(hex: 0x3FB950)
    static let yellow = Color(hex: 0xD29922)
    static let blue = Color(hex: 0x58A6FF)
    static let mono = Font.system(size: 12.5, design: .monospaced)
}

struct BuildView: View {
    let sim: BuildSim
    let t: Double

    var body: some View {
        GeometryReader { geo in
            let portrait = geo.size.height > geo.size.width
            VStack(spacing: 0) {
                titleBar
                AdaptiveStack(portrait: portrait) {
                    log
                    Rectangle().fill(Term.border).frame(width: portrait ? nil : 1, height: portrait ? 1 : nil)
                    side(portrait: portrait)
                        .frame(width: portrait ? nil : min(460, geo.size.width * 0.3),
                               height: portrait ? 300 : nil)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .background(Term.bg)
        }
    }

    private var titleBar: some View {
        HStack(spacing: 8) {
            ForEach([0xFF5F57, 0xFEBC2E, 0x28C840], id: \.self) { Circle().fill(Color(hex: UInt32($0))).frame(width: 12, height: 12) }
            Spacer()
            Text("\(sim.project.name) — build — zsh — 212×58").font(.system(size: 12, weight: .medium)).foregroundColor(Term.dim)
            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(height: 30)
        .background(Term.side)
        .overlay(Rectangle().fill(Term.border).frame(height: 1), alignment: .bottom)
    }

    private func color(_ kind: BuildSim.Line.Kind) -> Color {
        switch kind {
        case .plain: return Term.text
        case .dim: return Term.dim
        case .pass: return Term.green
        case .warn: return Term.yellow
        case .info: return Term.blue
        case .success: return Term.green
        }
    }

    private var log: some View {
        GeometryReader { geo in
            let n = max(1, Int((geo.size.height - 20) / 18))
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(sim.lines.suffix(n).enumerated()), id: \.offset) { _, line in
                    Text(line.text).font(Term.mono).foregroundColor(color(line.kind))
                        .fontWeight(line.kind == .success ? .bold : .regular)
                        .lineLimit(1).frame(height: 18, alignment: .leading)
                }
                HStack(spacing: 0) {
                    Text(sim.phase == .done ? "$ " : "").font(Term.mono).foregroundColor(Term.text)
                    Rectangle().fill(Int(t * 2) % 2 == 0 ? Term.text : .clear).frame(width: 8, height: 15)
                }
                .frame(height: 18)
            }
            .padding(10)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .bottomLeading)
        }
        .clipped()
    }

    private func side(portrait: Bool) -> some View {
        let grid = Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .top), count: portrait ? 2 : 1)
        return LazyVGrid(columns: grid, alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                heading("BUILD #\(sim.buildNumber)")
                progress("compile", done: sim.compiled, total: sim.compileTotal, color: Term.blue)
                progress("tests", done: sim.passed + sim.skipped, total: sim.testTotal, color: Term.green)
                row("passed", "\(sim.passed)", Term.green)
                row("skipped", "\(sim.skipped)", Term.yellow)
                row("failed", "0", Term.text)
                row("elapsed", String(format: "%.1fs", sim.buildTime), Term.text)
                row("cache hits", String(format: "%.0f%%", sim.cacheHit), Term.text)
            }
            VStack(alignment: .leading, spacing: 10) {
                heading("CPU · 10 CORES")
                HStack(alignment: .bottom, spacing: 5) {
                    ForEach(sim.cores.indices, id: \.self) { i in
                        VStack(spacing: 3) {
                            GeometryReader { g in
                                VStack(spacing: 0) {
                                    Spacer(minLength: 0)
                                    Rectangle().fill(sim.cores[i] > 85 ? Term.yellow : Term.green)
                                        .frame(height: g.size.height * sim.cores[i] / 100)
                                }
                            }
                            .background(Term.border)
                            Text("\(i)").font(.system(size: 9, design: .monospaced)).foregroundColor(Term.dim)
                        }
                    }
                }
                .frame(height: 74)
                heading("RECENT BUILDS")
                ForEach(Array(sim.history.reversed().enumerated()), id: \.offset) { _, build in
                    HStack {
                        Image(systemName: "checkmark.circle.fill").foregroundColor(Term.green)
                        Text(verbatim: "#\(build.number)").foregroundColor(Term.text)
                        Spacer()
                        Text("\(build.tests) tests · \(String(format: "%.0fs", build.seconds))").foregroundColor(Term.dim)
                    }
                    .font(.system(size: 12, design: .monospaced))
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Term.side)
    }

    private func heading(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundColor(Term.dim)
    }

    private func progress(_ label: String, done: Int, total: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).foregroundColor(Term.text)
                Spacer()
                Text("\(done)/\(total)").foregroundColor(Term.dim)
            }
            .font(.system(size: 12, design: .monospaced))
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Term.border)
                    Capsule().fill(color).frame(width: g.size.width * Double(done) / Double(max(total, 1)))
                }
            }
            .frame(height: 6)
        }
    }

    private func row(_ key: String, _ value: String, _ color: Color) -> some View {
        HStack {
            Text(key).foregroundColor(Term.dim)
            Spacer()
            Text(value).foregroundColor(color)
        }
        .font(.system(size: 12, design: .monospaced))
    }
}
