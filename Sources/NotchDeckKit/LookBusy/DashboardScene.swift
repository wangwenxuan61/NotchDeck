import SwiftUI

/// 监控大屏：线上服务的请求量、延迟、CPU 和报警，每秒刷新。
final class DashboardSim: BusySim {
    struct Alert { let name: String; var firing: Bool; var since: Double }

    let service: String
    let regions = ["us-east-1", "eu-west-1", "ap-southeast-1"]
    let pods = ["gateway", "auth", "billing", "search", "worker"]
    static let points = 90

    private var rng: SplitMix64
    private(set) var simTime = 0.0
    private(set) var requests: [History]
    private(set) var latency: [History]     // p50, p95, p99
    private(set) var cpu: [History]
    private(set) var errors = History(capacity: 45)
    private(set) var alerts: [Alert] = []
    private(set) var users = 18_400.0
    private var walks: [Walk]
    private var wait = 0.0

    init(projectName: String, seed: UInt64) {
        rng = SplitMix64(state: seed ^ 0xDA5B_0A2D)
        service = projectName.lowercased().replacingOccurrences(of: " ", with: "-")
        requests = Array(repeating: History(capacity: Self.points), count: 3)
        latency = Array(repeating: History(capacity: Self.points), count: 3)
        cpu = Array(repeating: History(capacity: Self.points), count: 5)
        walks = [Walk(1850, spread: 90, lo: 600), Walk(1240, spread: 70, lo: 400), Walk(760, spread: 50, lo: 200),
                 Walk(38, spread: 3, lo: 18), Walk(96, spread: 9, lo: 50), Walk(182, spread: 20, lo: 90),
                 Walk(46, spread: 4, lo: 5, hi: 98), Walk(31, spread: 3, lo: 5, hi: 98), Walk(58, spread: 5, lo: 5, hi: 98),
                 Walk(64, spread: 6, lo: 5, hi: 98), Walk(72, spread: 5, lo: 5, hi: 98)]
        alerts = [
            Alert(name: "HighLatencyP99 · search", firing: false, since: -2_100),
            Alert(name: "PodRestartLoop · worker", firing: false, since: -5_400),
            Alert(name: "DiskUsage > 80% · db-replica-2", firing: true, since: -840),
            Alert(name: "CertificateExpiry < 14d · edge", firing: false, since: -26_000),
            Alert(name: "Error budget burn · billing", firing: false, since: -9_800),
        ]
        for _ in 0..<Self.points { sample() }
    }

    func advance(_ dt: Double) {
        simTime += dt
        wait -= dt
        guard wait <= 0 else { return }
        wait = 1
        sample()
        if rng.chance(0.02) {
            let i = rng.int(0..<alerts.count)
            alerts[i].firing.toggle()
            alerts[i].since = simTime
        }
    }

    private func sample() {
        for i in 0..<3 { requests[i].push(walks[i].step(&rng)) }
        for i in 0..<3 { latency[i].push(walks[3 + i].step(&rng)) }
        for i in 0..<5 { cpu[i].push(walks[6 + i].step(&rng)) }
        errors.push(max(0, rng.range(-4, 9) + (rng.chance(0.05) ? rng.range(10, 30) : 0)))
        users = max(12_000, users + rng.range(-120, 140))
    }

    var totalRPS: Double { requests.map(\.last).reduce(0, +) }
    var errorRate: Double { errors.points.suffix(10).reduce(0, +) / 10 / max(totalRPS, 1) * 100 }
}

private enum Graf {
    static let bg = Color(hex: 0x111217)
    static let panel = Color(hex: 0x181B1F)
    static let border = Color(hex: 0x2A2D33)
    static let text = Color(hex: 0xCCCCDC)
    static let dim = Color(hex: 0x8E8E9E)
    static let green = Color(hex: 0x73BF69)
    static let yellow = Color(hex: 0xFADE2A)
    static let blue = Color(hex: 0x5794F2)
    static let orange = Color(hex: 0xFF9830)
    static let red = Color(hex: 0xF2495C)
    static let purple = Color(hex: 0xB877D9)
    static let palette = [green, blue, orange, purple, yellow]
    static let chart = ChartStyle(grid: Color(hex: 0x24272E), label: dim)
}

struct DashboardView: View {
    let sim: DashboardSim
    let t: Double
    private let clock = SceneClock("HH:mm:ss")

    var body: some View {
        GeometryReader { geo in
            let portrait = geo.size.height > geo.size.width
            VStack(spacing: 10) {
                header
                stats(columns: portrait ? 3 : 6)
                if portrait {
                    VStack(spacing: 10) {
                        requestsPanel
                        latencyPanel
                        cpuPanel
                        HStack(spacing: 10) { errorsPanel; alertsPanel }
                    }
                } else {
                    HStack(spacing: 10) {
                        VStack(spacing: 10) {
                            HStack(spacing: 10) { requestsPanel; latencyPanel }
                            HStack(spacing: 10) { cpuPanel; errorsPanel }
                        }
                        alertsPanel.frame(width: min(420, geo.size.width * 0.26))
                    }
                }
            }
            .padding(12)
            .frame(width: geo.size.width, height: geo.size.height)
            .background(Graf.bg)
        }
    }

    private var xLabels: [String] {
        (0..<4).map { clock.string(after: sim.simTime - Double(DashboardSim.points) * Double(3 - $0) / 3) }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.grid.2x2").foregroundColor(Graf.orange)
            Text("Dashboards").foregroundColor(Graf.dim)
            Text("/").foregroundColor(Graf.dim)
            Text("\(sim.service) · Production overview").foregroundColor(Graf.text).bold()
            Image(systemName: "star").foregroundColor(Graf.dim)
            Spacer()
            chip("env: prod")
            chip("cluster: k8s-prod-1")
            chip("⏱ Last 90 seconds")
            HStack(spacing: 4) {
                Image(systemName: "arrow.clockwise")
                    .rotationEffect(.degrees(sim.simTime.truncatingRemainder(dividingBy: 1) < 0.25 ? 180 : 0))
                Text("1s")
            }
            .modifier(Chip())
        }
        .font(.system(size: 13))
        .padding(.horizontal, 6)
        .frame(height: 34)
    }

    private func chip(_ text: String) -> some View { Text(text).modifier(Chip()) }

    private struct Chip: ViewModifier {
        func body(content: Content) -> some View {
            content.font(.system(size: 12)).foregroundColor(Graf.text)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Graf.panel)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Graf.border, lineWidth: 1))
        }
    }

    private func stats(columns: Int) -> some View {
        let p99 = sim.latency[2].last
        let items: [(String, String, Color)] = [
            ("Requests / s", grouped(Int(sim.totalRPS)), Graf.green),
            ("p99 latency", String(format: "%.0f ms", p99), p99 > 220 ? Graf.orange : Graf.green),
            ("Error rate", String(format: "%.2f%%", sim.errorRate), sim.errorRate > 0.8 ? Graf.red : Graf.green),
            ("Availability (30d)", "99.982%", Graf.green),
            ("Active users", grouped(Int(sim.users)), Graf.blue),
            ("Pods ready", "\(sim.pods.count * 3)/\(sim.pods.count * 3)", Graf.green),
        ]
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: columns), spacing: 10) {
            ForEach(items, id: \.0) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.0).font(.system(size: 12, weight: .medium)).foregroundColor(Graf.text)
                    Text(item.1).font(.system(size: 34, weight: .semibold)).foregroundColor(item.2)
                        .minimumScaleFactor(0.5).lineLimit(1)
                }
                .padding(12)
                .frame(maxWidth: .infinity, minHeight: 86, alignment: .leading)
                .background(Graf.panel)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Graf.border, lineWidth: 1))
            }
        }
    }

    private var requestsPanel: some View {
        GrafPanel(title: "HTTP requests / s by region", legend: zip(sim.regions, Graf.palette).map { ($0, $1) }) {
            Canvas { ctx, size in
                drawLineChart(ctx, size: size, series: sim.requests.map(\.points), colors: Graf.palette, style: Graf.chart,
                              fill: true, xLabels: xLabels)
            }
        }
    }

    private var latencyPanel: some View {
        GrafPanel(title: "Latency (ms)", legend: [("p50", Graf.green), ("p95", Graf.yellow), ("p99", Graf.red)]) {
            Canvas { ctx, size in
                drawLineChart(ctx, size: size, series: sim.latency.map(\.points), colors: [Graf.green, Graf.yellow, Graf.red],
                              style: Graf.chart, xLabels: xLabels)
            }
        }
    }

    private var cpuPanel: some View {
        GrafPanel(title: "CPU usage by deployment (%)", legend: zip(sim.pods, Graf.palette).map { ($0, $1) }) {
            Canvas { ctx, size in
                drawLineChart(ctx, size: size, series: sim.cpu.map(\.points), colors: Graf.palette, style: Graf.chart,
                              yMax: 100, xLabels: xLabels)
            }
        }
    }

    private var errorsPanel: some View {
        GrafPanel(title: "5xx responses / s", legend: [("5xx", Graf.red)]) {
            Canvas { ctx, size in
                let values = sim.errors.points
                let top = niceCeiling((values.max() ?? 1) * 1.1)
                let plot = CGRect(x: 36, y: 6, width: size.width - 40, height: size.height - 12)
                for i in 0...2 {
                    let y = plot.maxY - plot.height * Double(i) / 2
                    ctx.stroke(Path { $0.move(to: CGPoint(x: plot.minX, y: y)); $0.addLine(to: CGPoint(x: plot.maxX, y: y)) },
                               with: .color(Graf.chart.grid), lineWidth: 1)
                    ctx.draw(Text(String(format: "%.0f", top * Double(i) / 2)).font(Graf.chart.font).foregroundColor(Graf.dim),
                             at: CGPoint(x: plot.minX - 6, y: y), anchor: .trailing)
                }
                let w = plot.width / Double(max(values.count, 1))
                for (i, v) in values.enumerated() {
                    let h: CGFloat = plot.height * CGFloat(v / top)
                    let x: CGFloat = plot.minX + CGFloat(i) * w + 1
                    let rect = CGRect(x: x, y: plot.maxY - h, width: max(1, w - 2), height: h)
                    ctx.fill(Path(rect), with: .color(v > top * 0.6 ? Graf.red : Graf.red.opacity(0.55)))
                }
            }
        }
    }

    private var alertsPanel: some View {
        GrafPanel(title: "Alert rules", legend: []) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(sim.alerts.enumerated()), id: \.offset) { _, alert in
                    HStack(spacing: 8) {
                        Text(alert.firing ? "Firing" : "Normal")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(alert.firing ? .white : Graf.green)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 3).fill(alert.firing ? Graf.red : Graf.green.opacity(0.15)))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(alert.name).font(.system(size: 12)).foregroundColor(Graf.text).lineLimit(1)
                            Text("for \(duration(max(0, sim.simTime - alert.since)))").font(.system(size: 11)).foregroundColor(Graf.dim)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 7)
                    Rectangle().fill(Graf.border).frame(height: 1)
                }
                Spacer(minLength: 0)
            }
        }
    }
}

private struct GrafPanel<Content: View>: View {
    let title: String
    let legend: [(String, Color)]
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 13, weight: .medium)).foregroundColor(Graf.text)
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            if !legend.isEmpty {
                HStack(spacing: 14) {
                    ForEach(legend, id: \.0) { item in
                        HStack(spacing: 5) {
                            RoundedRectangle(cornerRadius: 1).fill(item.1).frame(width: 14, height: 4)
                            Text(item.0).font(.system(size: 11)).foregroundColor(Graf.dim)
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(Graf.panel)
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Graf.border, lineWidth: 1))
    }
}
