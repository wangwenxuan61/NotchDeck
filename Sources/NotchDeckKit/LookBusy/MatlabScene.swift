import SwiftUI

/// MATLAB 仿真：二维声波传播的有限差分脚本在跑，命令窗口打印迭代，图窗里的波场一帧帧更新，
/// 编辑器底部时不时在写后处理代码。
final class MatlabSim: BusySim {
    static let script = """
    %% wave2d_fdtd.m  2-D acoustic wave propagation (FDTD, 2nd order)
    clear; close all;

    % --- grid and medium ---------------------------------------------
    Nx = 512;  Ny = 512;          % grid points
    dx = 1e-4; dy = dx;           % spatial step [m]
    c0 = 1540;                    % speed of sound [m/s]
    c  = c0 * ones(Ny, Nx);
    c(300:360, 180:330) = 1580;   % inclusion
    dt = 0.4 * dx / max(c(:));    % CFL condition
    Nt = 2000;

    % --- source --------------------------------------------------------
    f0  = 5e6;                    % center frequency [Hz]
    src = [256, 64];
    t   = (0:Nt-1) * dt;
    s   = sin(2*pi*f0*t) .* exp(-((t - 3/f0) * f0).^2);

    % --- time stepping -------------------------------------------------
    p = zeros(Ny, Nx); pOld = p;
    C2 = (c * dt / dx).^2;
    tic
    for it = 1:Nt
        lap = del2(p) * 4;
        pNew = 2*p - pOld + C2 .* lap;
        pNew(src(1), src(2)) = pNew(src(1), src(2)) + s(it);
        pNew = applyPML(pNew, 32);
        pOld = p;  p = pNew;
        if mod(it, 20) == 0
            set(hImg, 'CData', p); drawnow limitrate;
            fprintf('it %4d / %d | t = %.2f us | max|p| = %.3f\\n', ...
                it, Nt, t(it)*1e6, max(abs(p(:))));
        end
    end
    toc
    """

    static let blocks = [
        "\n% --- post-processing ---------------------------------------------\nrf = p(:, 400);\nenv = abs(hilbert(rf));\nfigure; plot((1:Ny)*dx*1e3, 20*log10(env/max(env)));\nxlabel('depth [mm]'); ylabel('dB'); grid on;",
        "\n% compare with analytical arrival time\ntArr = norm(src - [256 400]) * dx / c0;\nfprintf('expected arrival: %.2f us\\n', tArr*1e6);",
        "\n% save snapshot for the report\nexportgraphics(gcf, 'fig/wavefield_it2000.pdf', 'ContentType', 'vector');\nsave('results/run_inclusion.mat', 'p', 'c', 'dt', '-v7.3');",
        "\n% sweep source frequency\nfreqs = [2.5 5 7.5] * 1e6;\nfor k = 1:numel(freqs)\n    res(k) = runSim(c, freqs(k), Nt); %#ok<SAGROW>\nend",
    ]

    private var rng: SplitMix64
    private(set) var iteration = 0
    let total = 2000
    private(set) var simTime = 0.0
    private(set) var command: [String] = []
    private(set) var residual = History(capacity: 120)
    private(set) var typist = Typist()
    private var block = 0
    private var iterAcc = 0.0
    private var typeWait = 4.0
    private var restartWait = 0.0
    private var runStart = 0.0

    init(seed: UInt64) {
        rng = SplitMix64(state: seed ^ 0x3A71_AB00)
        block = rng.int(0..<Self.blocks.count)
        command = [">> wave2d_fdtd"]
        iteration = rng.int(300..<1100) / 20 * 20
        var r = 1.0
        for _ in 0..<(iteration / 20) { r *= rng.range(0.93, 0.99); residual.push(r) }
        runStart = -Double(iteration) / 4.2
        // 打开时这一轮已经跑了一段，命令窗口里已经有输出。
        for it in stride(from: 20, through: iteration, by: 20) {
            command.append(String(format: "it %4d / %d | t = %.2f us | max|p| = %.3f", it, total, Double(it) * 0.0259, rng.range(0.25, 0.34)))
        }
    }

    var appended: String { typist.text }

    func advance(_ dt: Double) {
        simTime += dt
        if restartWait > 0 {
            restartWait -= dt
            if restartWait <= 0 {
                iteration = 0
                runStart = simTime
                residual = History(capacity: 120)
                print(">> wave2d_fdtd")
            }
        } else {
            iterAcc += dt * 4.2
            while iterAcc >= 1 {
                iterAcc -= 1
                iteration += 1
                if iteration % 20 == 0 {
                    let last = residual.points.last ?? 1
                    residual.push(last * rng.range(0.93, 0.995))
                    let tUs = Double(iteration) * 0.0259
                    print(String(format: "it %4d / %d | t = %.2f us | max|p| = %.3f", iteration, total, tUs, rng.range(0.25, 0.34)))
                }
                if iteration >= total {
                    print(String(format: "Elapsed time is %.6f seconds.", simTime - runStart))
                    restartWait = rng.range(4, 8)
                    break
                }
            }
        }
        typeWait -= dt
        if typeWait <= 0 && !typist.isActive {
            if typist.isDone && !typist.text.isEmpty {
                typist.clear()
                block = (block + 1) % Self.blocks.count
                typeWait = rng.range(3, 6)
            } else {
                typist.start(Self.blocks[block], speed: 11...18, rng: &rng)
            }
        }
        typist.advance(dt, rng: &rng)
        if typist.isDone && typeWait <= 0 { typeWait = rng.range(6, 10) }
    }

    func boost() { typist.boost() }

    private func print(_ line: String) {
        command.append(line)
        if command.count > 120 { command.removeFirst(command.count - 120) }
    }

    /// 波场：从声源发出的圆形波，碰到内含物有一部分反射。返回 -1...1。
    func field(x: Double, y: Double, t: Double) -> Double {
        // 声源发出的是一个短脉冲：只有波前附近一圈有起伏，往外传时慢慢变弱。
        let front = Double(iteration) / Double(total) * 1.15 + 0.05
        func pulse(_ r: Double, _ at: Double) -> Double {
            let d = r - at
            return exp(-pow(d * 16, 2)) * sin(d * 48) / sqrt(max(r, 0.05) * 6)
        }
        var v = pulse(hypot(x - 0.125, y - 0.5), front)
        // 碰到内含物后反射回来的弱一些的波。
        let reflected = front - 0.42
        if reflected > 0 { v += 0.45 * pulse(hypot(x - 0.5, y - 0.64), reflected) }
        // 背景里一点散斑，看起来像真实的仿真结果。
        v += 0.03 * sin(x * 91 + y * 57) * cos(x * 43 - y * 77)
        return max(-1, min(1, v * 1.8))
    }
}

private enum ML {
    static let strip = Color(hex: 0xF2F2F2)
    static let tab = Color(hex: 0x0E6EB8)
    static let border = Color(hex: 0xD0D0D0)
    static let pane = Color(hex: 0xFAFAFA)
    static let text = Color(hex: 0x1A1A1A)
    static let dim = Color(hex: 0x6E6E6E)
    static let keyword = Color(hex: 0x0E00FF)
    static let comment = Color(hex: 0x228B22)
    static let string = Color(hex: 0xA020F0)
    static let mono = Font.system(size: 12.5, design: .monospaced)
    static let keywords: Set<String> = ["for", "end", "if", "else", "elseif", "while", "function", "return", "break", "clear", "close", "all", "tic", "toc"]

    /// parula 色图的几个关键色，按 0...1 插值。
    static let parula: [(Double, Double, Double)] = [
        (0.208, 0.166, 0.529), (0.059, 0.360, 0.867), (0.078, 0.553, 0.831), (0.024, 0.674, 0.733),
        (0.196, 0.765, 0.557), (0.651, 0.749, 0.416), (0.988, 0.733, 0.243), (0.976, 0.984, 0.055),
    ]

    static func color(_ v: Double) -> Color {
        let x = min(max(v, 0), 1) * Double(parula.count - 1)
        let i = min(Int(x), parula.count - 2), f = x - Double(i)
        let a = parula[i], b = parula[i + 1]
        return Color(.sRGB, red: a.0 + (b.0 - a.0) * f, green: a.1 + (b.1 - a.1) * f, blue: a.2 + (b.2 - a.2) * f)
    }
}

struct MatlabView: View {
    let sim: MatlabSim
    let t: Double

    var body: some View {
        GeometryReader { geo in
            let portrait = geo.size.height > geo.size.width
            VStack(spacing: 0) {
                toolstrip
                if portrait {
                    VStack(spacing: 0) {
                        editor.frame(height: geo.size.height * 0.36)
                        figure.frame(height: geo.size.height * 0.34)
                        commandWindow
                    }
                } else {
                    HStack(spacing: 0) {
                        folder.frame(width: 220)
                        VStack(spacing: 0) {
                            editor
                            commandWindow.frame(height: geo.size.height * 0.3)
                        }
                        VStack(spacing: 0) {
                            workspace.frame(height: geo.size.height * 0.3)
                            figure
                        }
                        .frame(width: geo.size.width * 0.34)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .background(Color.white)
        }
    }

    private var toolstrip: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(["HOME", "PLOTS", "APPS", "EDITOR", "PUBLISH", "VIEW"], id: \.self) { tab in
                    Text(tab).font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(tab == "EDITOR" ? .white : ML.text)
                        .padding(.horizontal, 16).frame(height: 28)
                        .background(tab == "EDITOR" ? ML.tab : .clear)
                }
                Spacer()
                Text("Search Documentation").font(.system(size: 11.5)).foregroundColor(ML.dim)
                    .padding(.horizontal, 10).padding(.vertical, 3)
                    .background(Color.white).overlay(RoundedRectangle(cornerRadius: 3).stroke(ML.border))
                    .padding(.trailing, 10)
            }
            HStack(spacing: 26) {
                tool("doc.badge.plus", "New")
                tool("folder", "Open")
                tool("square.and.arrow.down", "Save")
                Rectangle().fill(ML.border).frame(width: 1, height: 44)
                tool("magnifyingglass", "Find")
                tool("text.badge.checkmark", "Comment")
                tool("increase.indent", "Indent")
                Rectangle().fill(ML.border).frame(width: 1, height: 44)
                tool("smallcircle.filled.circle", "Breakpoints")
                tool("play.fill", "Run", color: Color(hex: 0x2E9E3E))
                tool("forward.end", "Run and\nAdvance")
                tool("stop.fill", "Stop", color: Color(hex: 0xC8302C))
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(height: 62)
            .background(ML.strip)
            .overlay(Rectangle().fill(ML.border).frame(height: 1), alignment: .bottom)
            HStack(spacing: 6) {
                Image(systemName: "folder.fill").foregroundColor(Color(hex: 0xE0A72E))
                Text("/ Users / me / research / wave-sim / src").font(.system(size: 11.5)).foregroundColor(ML.dim)
                Spacer()
            }
            .padding(.horizontal, 10).frame(height: 24)
            .overlay(Rectangle().fill(ML.border).frame(height: 1), alignment: .bottom)
        }
        .background(Color(hex: 0xE6E6E6))
    }

    private func tool(_ symbol: String, _ title: String, color: Color = ML.text) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 18)).foregroundColor(color)
            Text(title).font(.system(size: 10)).foregroundColor(ML.text).multilineTextAlignment(.center)
        }
    }

    private func pane<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.system(size: 11.5, weight: .semibold)).foregroundColor(ML.text)
                .padding(.horizontal, 8).frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                .background(Color(hex: 0xE9EEF4))
            content().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .overlay(Rectangle().stroke(ML.border, lineWidth: 1))
    }

    private var folder: some View {
        pane("Current Folder") {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(["applyPML.m", "runSim.m", "wave2d_fdtd.m", "beamform_das.m", "make_phantom.m", "plot_bmode.m",
                         "results", "fig", "data", "README.md"], id: \.self) { name in
                    HStack(spacing: 6) {
                        Image(systemName: name.contains(".") ? "doc.text" : "folder.fill")
                            .foregroundColor(name.contains(".") ? Color(hex: 0xD06B2B) : Color(hex: 0xE0A72E))
                        Text(name).font(.system(size: 12)).foregroundColor(ML.text)
                    }
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(name == "wave2d_fdtd.m" ? Color(hex: 0xCCE4F7) : .clear)
                }
            }
            .padding(6)
        }
    }

    private func highlighted(_ line: String) -> AttributedString {
        var out = AttributedString()
        func emit(_ s: String, _ c: Color) { var a = AttributedString(s); a.foregroundColor = c; out += a }
        var code = line
        var comment = ""
        if let i = line.firstIndex(of: "%"), !line[..<i].contains("'") {
            code = String(line[..<i]); comment = String(line[i...])
        }
        var word = ""
        var inString = false
        for ch in code {
            if ch == "'" { emit(word, ML.keywords.contains(word) ? ML.keyword : ML.text); word = ""; inString.toggle(); emit("'", ML.string); continue }
            if inString { emit(String(ch), ML.string); continue }
            if ch.isLetter || ch.isNumber || ch == "_" { word.append(ch); continue }
            emit(word, ML.keywords.contains(word) ? ML.keyword : ML.text)
            word = ""
            emit(String(ch), ML.text)
        }
        emit(word, ML.keywords.contains(word) ? ML.keyword : ML.text)
        emit(comment, ML.comment)
        return out
    }

    private var editor: some View {
        let lines = (MatlabSim.script + sim.appended).components(separatedBy: "\n")
        return pane("Editor — wave2d_fdtd.m") {
            GeometryReader { geo in
                let n = max(1, Int(geo.size.height / 19) - 1)
                let start = max(0, lines.count - n)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(start..<lines.count, id: \.self) { i in
                        HStack(spacing: 0) {
                            Text("\(i + 1)").font(.system(size: 11, design: .monospaced)).foregroundColor(ML.dim)
                                .frame(width: 38, alignment: .trailing).padding(.trailing, 10)
                            Text(highlighted(lines[i])).font(ML.mono).lineLimit(1)
                            if i == lines.count - 1 && sim.typist.isActive {
                                Rectangle().fill(Int(t * 2) % 2 == 0 ? ML.text : .clear).frame(width: 1.5, height: 15)
                            }
                        }
                        .frame(height: 19)
                    }
                }
                .padding(.top, 4)
            }
            .clipped()
        }
    }

    private var commandWindow: some View {
        pane("Command Window") {
            GeometryReader { geo in
                let n = max(1, Int(geo.size.height / 18) - 1)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(sim.command.suffix(n).enumerated()), id: \.offset) { _, line in
                        Text(line).font(ML.mono).foregroundColor(ML.text).lineLimit(1).frame(height: 18)
                    }
                    HStack(spacing: 2) {
                        Text("fx").font(.system(size: 11, weight: .bold).italic()).foregroundColor(ML.dim)
                        Text(">>").font(ML.mono)
                    }
                    .frame(height: 18)
                }
                .padding(.horizontal, 8)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .bottomLeading)
            }
            .clipped()
        }
    }

    private var workspace: some View {
        let rows: [(String, String)] = [
            ("C2", "512x512 double"), ("Nt", "2000"), ("Nx", "512"), ("Ny", "512"), ("c", "512x512 double"),
            ("c0", "1540"), ("dt", "2.5316e-08"), ("dx", "1.0000e-04"), ("f0", "5000000"), ("it", "\(sim.iteration)"),
            ("p", "512x512 double"), ("pOld", "512x512 double"), ("s", "1x2000 double"), ("src", "[256,64]"),
        ]
        return pane("Workspace") {
            VStack(alignment: .leading, spacing: 0) {
                // 面板矮的时候放不下全部变量，多出来的裁掉。
                HStack {
                    Text("Name").frame(width: 90, alignment: .leading)
                    Text("Value")
                }
                .font(.system(size: 11, weight: .semibold)).foregroundColor(ML.dim)
                .padding(.horizontal, 8).padding(.vertical, 4)
                ForEach(rows, id: \.0) { row in
                    HStack {
                        Text(row.0).frame(width: 90, alignment: .leading)
                        Text(row.1).foregroundColor(ML.dim)
                    }
                    .font(.system(size: 12)).padding(.horizontal, 8).frame(height: 18)
                }
            }
        }
    }

    private var figure: some View {
        pane("Figure 1: wavefield") {
            VStack(spacing: 6) {
                Canvas { ctx, size in
                    let side = min(size.width - 70, size.height - 10)
                    let origin = CGPoint(x: (size.width - side) / 2 - 18, y: 4)
                    let n = 72
                    let cellSize = side / Double(n)
                    for j in 0..<n {
                        for i in 0..<n {
                            let v = sim.field(x: Double(i) / Double(n), y: Double(j) / Double(n), t: t)
                            let rect = CGRect(x: origin.x + Double(i) * cellSize, y: origin.y + Double(j) * cellSize,
                                              width: cellSize + 0.6, height: cellSize + 0.6)
                            ctx.fill(Path(rect), with: .color(ML.color((v + 1) / 2)))
                        }
                    }
                    let inclusion = CGRect(x: origin.x + side * 0.35, y: origin.y + side * 0.586, width: side * 0.3, height: side * 0.12)
                    ctx.stroke(Path(inclusion), with: .color(.white.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    for k in 0..<40 {
                        let rect = CGRect(x: origin.x + side + 12, y: origin.y + side * CGFloat(39 - k) / 40, width: 12, height: side / 40 + 0.5)
                        ctx.fill(Path(rect), with: .color(ML.color(Double(k) / 39)))
                    }
                    ctx.draw(Text(String(format: "it = %d", sim.iteration)).font(.system(size: 11, design: .monospaced)).foregroundColor(.white),
                             at: CGPoint(x: origin.x + 8, y: origin.y + 12), anchor: .leading)
                }
                Canvas { ctx, size in
                    let points = sim.residual.points.map { log10(max($0, 1e-6)) }
                    let plot = CGRect(x: 40, y: 4, width: size.width - 50, height: size.height - 8)
                    ctx.stroke(Path(plot), with: .color(ML.border), lineWidth: 1)
                    let lo = min(points.min() ?? -2, -1.5)
                    for e in stride(from: 0, through: Int(lo.rounded(.down)), by: -1) {
                        let y = plot.minY + plot.height * Double(-e) / -lo
                        ctx.draw(Text("1e\(e)").font(.system(size: 9)).foregroundColor(ML.dim), at: CGPoint(x: plot.minX - 4, y: y), anchor: .trailing)
                    }
                    var path = Path()
                    for (i, v) in points.enumerated() {
                        let p = CGPoint(x: plot.minX + plot.width * Double(i) / Double(max(MatlabSim.total() - 1, 1)),
                                        y: plot.minY + plot.height * (-v) / -lo)
                        i == 0 ? path.move(to: p) : path.addLine(to: p)
                    }
                    ctx.stroke(path, with: .color(Color(hex: 0x0072BD)), lineWidth: 1.5)
                }
                .frame(height: 90)
            }
            .padding(8)
        }
    }
}

extension MatlabSim {
    /// 残差曲线一共有多少个点（每 20 步一个）。
    static func total() -> Int { 2000 / 20 }
}
