import SwiftUI

private enum Dash {
    static let bg = Color(hex: 0x0E1016)
    static let panel = Color(hex: 0x161922)
    static let border = Color(hex: 0x262B38)
    static let grid = Color(hex: 0x232835)
    static let text = Color(hex: 0xD6D9E0)
    static let dim = Color(hex: 0x8089A0)
    static let train = Color(hex: 0x5B9CFF)
    static let val = Color(hex: 0xFFB454)
    static let good = Color(hex: 0x3FD07F)
    static let mono = Font.system(size: 12, design: .monospaced)
}

struct TrainingView: View {
    let sim: TrainingSim
    let t: Double

    var body: some View {
        GeometryReader { geo in
            if geo.size.height > geo.size.width {
                portrait(geo.size)
            } else {
                landscape(geo.size)
            }
        }
    }

    /// 竖屏：图表、nvidia-smi 和日志上下排。
    private func portrait(_ size: CGSize) -> some View {
        VStack(spacing: 0) {
            header
            VStack(spacing: 14) {
                cards
                Panel(title: "train/loss  ·  val/loss") { lossChart }
                HStack(spacing: 14) {
                    Panel(title: "learning rate (cosine, warmup 2k)") { lrChart }
                    Panel(title: "GPU utilization · mean of 4") { utilChart }
                }
                .frame(height: size.height * 0.13)
                smiPanel
                logPanel.frame(height: size.height * 0.2)
            }
            .padding(14)
        }
        .background(Dash.bg)
    }

    private func landscape(_ size: CGSize) -> some View {
        Group {
            VStack(spacing: 0) {
                header
                HStack(alignment: .top, spacing: 14) {
                    VStack(spacing: 14) {
                        cards
                        Panel(title: "train/loss  ·  val/loss") { lossChart }
                        HStack(spacing: 14) {
                            Panel(title: "learning rate (cosine, warmup 2k)") { lrChart }
                            Panel(title: "GPU utilization · mean of 4 · last 90 s") { utilChart }
                        }
                        .frame(height: size.height * 0.2)
                    }
                    VStack(spacing: 14) {
                        smiPanel
                        Panel(title: "processes") { processes }
                    }
                    .frame(width: 640)
                }
                .padding(14)
                logPanel
                    .frame(height: size.height * 0.24)
                    .padding([.horizontal, .bottom], 14)
            }
            .background(Dash.bg)
        }
    }

    private var smiPanel: some View {
        Panel(title: "nvidia-smi") {
            Text(sim.nvidiaSMI())
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundColor(Dash.text)
                .fixedSize()
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var header: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                Circle().fill(Dash.good).frame(width: 9, height: 9)
                    .opacity(0.55 + 0.45 * sin(t * 3))
                Text("running").foregroundColor(Dash.good)
            }
            Text(sim.runName).foregroundColor(.white).bold()
            Text("·").foregroundColor(Dash.dim)
            Text("elapsed \(duration(sim.elapsed))").foregroundColor(Dash.dim)
            Text("·").foregroundColor(Dash.dim)
            Text("step \(grouped(Int(sim.step))) / \(grouped(Int(sim.total)))").foregroundColor(Dash.text)
            ProgressBar(value: sim.step / sim.total).frame(width: 220, height: 6)
            Text("\(String(format: "%.1f", 100 * sim.step / sim.total))%").foregroundColor(Dash.text)
            Spacer()
            Text("ETA \(duration(sim.eta))").foregroundColor(Dash.dim)
        }
        .font(.system(size: 13, design: .monospaced))
        .padding(.horizontal, 18)
        .frame(height: 46)
        .background(Dash.panel)
        .overlay(Rectangle().fill(Dash.border).frame(height: 1), alignment: .bottom)
    }

    private var cards: some View {
        let lastVal = sim.val.last?.loss ?? 0
        let prevVal = sim.val.dropLast().last?.loss ?? lastVal
        let util = sim.utilHistory.last ?? 97
        return HStack(spacing: 14) {
            TrainingPanelCard(label: "train/loss", value: String(format: "%.4f", sim.smoothedLoss), note: "↓ smoothed", noteColor: Dash.good)
            TrainingPanelCard(label: "val/loss", value: String(format: "%.4f", lastVal),
                 note: String(format: "%@ %.4f", lastVal <= prevVal ? "↓" : "↑", abs(lastVal - prevVal)),
                 noteColor: lastVal <= prevVal ? Dash.good : Dash.val)
            TrainingPanelCard(label: "learning rate", value: String(format: "%.2e", sim.lr(at: sim.step)), note: "cosine decay", noteColor: Dash.dim)
            TrainingPanelCard(label: "throughput", value: "\(grouped(Int(sim.throughput)))", note: "samples/s · bs \(sim.batch)", noteColor: Dash.dim)
            TrainingPanelCard(label: "GPU util", value: "\(Int(util))%", note: "4 × H100 80GB", noteColor: Dash.dim)
        }
        .frame(height: 86)
    }

    private var lossChart: some View {
        Canvas { ctx, size in
            let xMax = max(sim.step * 1.04, 10_000)
            let yMin = 0.3, yMax = 3.0
            let plot = CGRect(x: 46, y: 6, width: size.width - 56, height: size.height - 28)
            drawGrid(ctx, plot, xMax: xMax, yMin: yMin, yMax: yMax, yTicks: [0.5, 1.0, 1.5, 2.0, 2.5, 3.0], yFormat: "%.1f")
            func pt(_ s: Double, _ v: Double) -> CGPoint {
                CGPoint(x: plot.minX + plot.width * s / xMax, y: plot.maxY - plot.height * (min(max(v, yMin), yMax) - yMin) / (yMax - yMin))
            }
            var raw = Path()
            for (i, p) in sim.train.enumerated() { i == 0 ? raw.move(to: pt(p.step, p.loss)) : raw.addLine(to: pt(p.step, p.loss)) }
            ctx.stroke(raw, with: .color(Dash.train.opacity(0.28)), lineWidth: 1)
            var smooth = Path()
            var ema = sim.train.first?.loss ?? 0
            for (i, p) in sim.train.enumerated() {
                ema = i == 0 ? p.loss : ema * 0.85 + p.loss * 0.15
                i == 0 ? smooth.move(to: pt(p.step, ema)) : smooth.addLine(to: pt(p.step, ema))
            }
            ctx.stroke(smooth, with: .color(Dash.train), lineWidth: 2)
            var vpath = Path()
            for (i, p) in sim.val.enumerated() { i == 0 ? vpath.move(to: pt(p.step, p.loss)) : vpath.addLine(to: pt(p.step, p.loss)) }
            ctx.stroke(vpath, with: .color(Dash.val), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            for p in sim.val {
                let c = pt(p.step, p.loss)
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 2.2, y: c.y - 2.2, width: 4.4, height: 4.4)), with: .color(Dash.val))
            }
            if let last = sim.train.last {
                let c = pt(last.step, ema)
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)), with: .color(Dash.train))
                ctx.draw(Text(String(format: "%.4f", ema)).font(Dash.mono).foregroundColor(Dash.train), at: CGPoint(x: c.x - 8, y: c.y - 14), anchor: .trailing)
            }
            ctx.draw(Text("— train (EMA)").font(Dash.mono).foregroundColor(Dash.train), at: CGPoint(x: plot.maxX - 150, y: plot.minY + 10), anchor: .leading)
            ctx.draw(Text("- - val").font(Dash.mono).foregroundColor(Dash.val), at: CGPoint(x: plot.maxX - 150, y: plot.minY + 28), anchor: .leading)
        }
    }

    private var lrChart: some View {
        Canvas { ctx, size in
            let plot = CGRect(x: 58, y: 6, width: size.width - 66, height: size.height - 26)
            drawGrid(ctx, plot, xMax: sim.total, yMin: 0, yMax: sim.peakLR * 1.08, yTicks: [1e-4, 2e-4, 3e-4], yFormat: "%.0e")
            var p = Path()
            for i in 0...200 {
                let s = sim.total * Double(i) / 200
                let c = CGPoint(x: plot.minX + plot.width * s / sim.total, y: plot.maxY - plot.height * sim.lr(at: s) / (sim.peakLR * 1.08))
                i == 0 ? p.move(to: c) : p.addLine(to: c)
            }
            ctx.stroke(p, with: .color(Dash.dim.opacity(0.6)), style: StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
            var done = Path()
            let n = Int(200 * sim.step / sim.total)
            for i in 0...max(1, n) {
                let s = sim.total * Double(i) / 200
                let c = CGPoint(x: plot.minX + plot.width * s / sim.total, y: plot.maxY - plot.height * sim.lr(at: s) / (sim.peakLR * 1.08))
                i == 0 ? done.move(to: c) : done.addLine(to: c)
            }
            ctx.stroke(done, with: .color(Color(hex: 0xB48CFF)), lineWidth: 2)
            let x = plot.minX + plot.width * sim.step / sim.total
            ctx.stroke(Path { $0.move(to: CGPoint(x: x, y: plot.minY)); $0.addLine(to: CGPoint(x: x, y: plot.maxY)) },
                       with: .color(.white.opacity(0.35)), lineWidth: 1)
        }
    }

    private var utilChart: some View {
        Canvas { ctx, size in
            let plot = CGRect(x: 40, y: 6, width: size.width - 48, height: size.height - 26)
            for v in [80.0, 90.0, 100.0] {
                let y = plot.maxY - plot.height * (v - 75) / 27
                ctx.stroke(Path { $0.move(to: CGPoint(x: plot.minX, y: y)); $0.addLine(to: CGPoint(x: plot.maxX, y: y)) }, with: .color(Dash.grid), lineWidth: 1)
                ctx.draw(Text("\(Int(v))").font(.system(size: 10, design: .monospaced)).foregroundColor(Dash.dim), at: CGPoint(x: plot.minX - 6, y: y), anchor: .trailing)
            }
            let h = sim.utilHistory
            guard h.count > 1 else { return }
            var p = Path(), area = Path()
            for (i, v) in h.enumerated() {
                let c = CGPoint(x: plot.minX + plot.width * Double(i) / Double(h.count - 1), y: plot.maxY - plot.height * (v - 75) / 27)
                if i == 0 { p.move(to: c); area.move(to: CGPoint(x: c.x, y: plot.maxY)); area.addLine(to: c) } else { p.addLine(to: c); area.addLine(to: c) }
            }
            area.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY)); area.closeSubpath()
            ctx.fill(area, with: .color(Dash.good.opacity(0.12)))
            ctx.stroke(p, with: .color(Dash.good), lineWidth: 1.6)
        }
    }

    private func drawGrid(_ ctx: GraphicsContext, _ plot: CGRect, xMax: Double, yMin: Double, yMax: Double, yTicks: [Double], yFormat: String) {
        for v in yTicks {
            let y = plot.maxY - plot.height * (v - yMin) / (yMax - yMin)
            ctx.stroke(Path { $0.move(to: CGPoint(x: plot.minX, y: y)); $0.addLine(to: CGPoint(x: plot.maxX, y: y)) }, with: .color(Dash.grid), lineWidth: 1)
            ctx.draw(Text(String(format: yFormat, v)).font(.system(size: 10, design: .monospaced)).foregroundColor(Dash.dim),
                     at: CGPoint(x: plot.minX - 6, y: y), anchor: .trailing)
        }
        let stepTick = xMax > 120_000 ? 50_000.0 : xMax > 40_000 ? 10_000.0 : 5_000.0
        var x = 0.0
        while x <= xMax {
            let px = plot.minX + plot.width * x / xMax
            ctx.draw(Text(x == 0 ? "0" : "\(Int(x / 1000))k").font(.system(size: 10, design: .monospaced)).foregroundColor(Dash.dim),
                     at: CGPoint(x: px, y: plot.maxY + 10), anchor: .center)
            x += stepTick
        }
        ctx.stroke(Path { $0.move(to: CGPoint(x: plot.minX, y: plot.maxY)); $0.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY)) }, with: .color(Dash.border), lineWidth: 1)
    }

    private var processes: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(0..<4, id: \.self) { i in
                let g = sim.gpus[i]
                HStack {
                    Text("GPU \(i)").foregroundColor(Dash.dim)
                    Text("\(3_141_000 + i * 17)").foregroundColor(Dash.dim)
                    Text("torchrun train.py --config configs/\(sim.runName.split(separator: "/").first ?? "run").yaml --local-rank \(i)")
                        .foregroundColor(Dash.text).lineLimit(1)
                    Spacer()
                    Text("\(Int(g.memMiB))MiB").foregroundColor(Dash.text)
                }
            }
            Divider().overlay(Dash.border).padding(.vertical, 8)
            let best = sim.val.min(by: { $0.loss < $1.loss })
            let toEval = Int(ceil(sim.step / 2000) * 2000 - sim.step)
            let toCkpt = Int(ceil(sim.step / 5000) * 5000 - sim.step)
            Group {
                row("best val_loss", best.map { String(format: "%.4f  @ step %@", $0.loss, grouped(Int($0.step))) } ?? "—")
                row("next eval", "in \(grouped(toEval)) steps")
                row("next checkpoint", "in \(grouped(toCkpt)) steps  ·  keep last 3")
                row("dataloader", "16 workers · prefetch 4 · queue \(88 + Int(sim.step) % 11)%")
                row("host", "CPU \(54 + Int(sim.step / 7) % 14)% · RAM 418 / 1024 GB · NVMe 2.7 GB/s")
                row("precision", "bf16 · grad accum 4 · ZeRO-2 · torch.compile on")
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11, design: .monospaced))
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k).foregroundColor(Dash.dim).frame(width: 130, alignment: .leading)
            Text(v).foregroundColor(Dash.text)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private var logPanel: some View {
        Panel(title: "stdout · train.log") {
            LogTail(lines: sim.log, lineHeight: 17) { line in
                Text(line)
                    .foregroundColor(line.contains("eval") ? Dash.val : line.contains("checkpoint") ? Dash.good : Dash.text)
                    .font(Dash.mono)
            }
        }
    }
}

private struct Panel<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 11.5, weight: .semibold, design: .monospaced)).foregroundColor(Dash.dim)
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(12)
        .background(Dash.panel)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Dash.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct TrainingPanelCard: View {
    let label: String
    let value: String
    let note: String
    let noteColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11, design: .monospaced)).foregroundColor(Dash.dim)
            Text(value).font(.system(size: 24, weight: .semibold, design: .monospaced)).foregroundColor(.white)
            Text(note).font(.system(size: 11, design: .monospaced)).foregroundColor(noteColor)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Dash.panel)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Dash.border, lineWidth: 1))
    }
}

private struct ProgressBar: View {
    let value: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Dash.grid)
                Capsule().fill(Dash.train).frame(width: g.size.width * value)
            }
        }
    }
}
