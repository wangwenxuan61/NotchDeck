import SwiftUI

func formatTemperature(_ value: Double?) -> String? {
    value.map { "\(Int($0.rounded()))°C" }
}

struct Ring: View {
    let value: Double
    let color: Color

    var body: some View {
        ZStack {
            Circle().stroke(Theme.track, lineWidth: 4.5)
            Circle()
                .trim(from: 0, to: max(min(value, 1), 0.001))
                .stroke(color, style: StrokeStyle(lineWidth: 4.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int((value * 100).rounded()))%")
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
        }
        .frame(width: 40, height: 40)
        .animation(.easeOut(duration: 0.4), value: value)
    }
}

struct MonitorCard: View {
    @ObservedObject private var monitor = SystemMonitor.shared
    let onOpen: () -> Void

    private func column(_ title: String, value: Double, color: Color, detail: String?, detailColor: Color = Theme.teal) -> some View {
        VStack(spacing: 3) {
            Ring(value: value, color: color)
            HStack(spacing: 4) {
                Text(title).foregroundStyle(Theme.secondary)
                if let detail { Text(detail).foregroundStyle(detailColor) }
            }
            .font(.system(size: 11, weight: .medium))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }

    private var diskFraction: Double {
        monitor.diskTotal > 0 ? Double(monitor.diskUsed) / Double(monitor.diskTotal) : 0
    }

    private func gigabytes(_ bytes: Int64) -> String { "\(bytes / 1_000_000_000)G" }

    var body: some View {
        Button(action: onOpen) {
            Card {
                VStack(spacing: 5) {
                    HStack(spacing: 0) {
                        column("CPU", value: monitor.cpu, color: Theme.blue, detail: formatTemperature(monitor.cpuTemp))
                        column("GPU", value: monitor.gpu, color: Theme.purple, detail: formatTemperature(monitor.gpuTemp))
                        column(L("内存"), value: monitor.memory, color: Theme.orange, detail: monitor.memoryPressure.title, detailColor: Theme.secondary)
                    }
                    VStack(spacing: 3) {
                        HStack {
                            Text(L("磁盘")).foregroundStyle(Theme.secondary)
                            Spacer()
                            Text("\(gigabytes(monitor.diskUsed)) / \(gigabytes(monitor.diskTotal))")
                                .foregroundStyle(Theme.secondary)
                                .monospacedDigit()
                            Text("\(Int((diskFraction * 100).rounded()))%").monospacedDigit()
                        }
                        .font(.system(size: 11, weight: .medium))
                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Theme.track)
                                Capsule().fill(Theme.orange).frame(width: proxy.size.width * diskFraction)
                            }
                        }
                        .frame(height: 5)
                    }
                    HStack(spacing: 10) {
                        Text(L("网速")).foregroundStyle(Theme.secondary)
                        Spacer()
                        Text("↓ \(formatSpeed(monitor.downloadSpeed))").monospacedDigit()
                        Text("↑ \(formatSpeed(monitor.uploadSpeed))").monospacedDigit()
                    }
                    .font(.system(size: 11, weight: .medium))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("查看监控详情"))
    }
}

func formatSpeed(_ bytesPerSecond: Double) -> String {
    bytesPerSecond >= 1_000_000
        ? String(format: "%.1f MB/s", bytesPerSecond / 1_000_000)
        : String(format: "%.0f KB/s", bytesPerSecond / 1_000)
}

/// 菜单栏空间有限，只保留数字和单位首字母。
func formatCompactSpeed(_ bytesPerSecond: Double) -> String {
    bytesPerSecond >= 1_000_000
        ? String(format: "%.1fM", bytesPerSecond / 1_000_000)
        : String(format: "%.0fK", bytesPerSecond / 1_000)
}

struct MonitorPage: View {
    private enum ChartKind: CaseIterable {
        case temperature, cpu, memory

        var title: String {
            switch self {
            case .temperature: return L("温度")
            case .cpu: return "CPU"
            case .memory: return L("内存")
            }
        }
    }

    @ObservedObject var model: PanelModel
    @ObservedObject private var monitor = SystemMonitor.shared
    @State private var chartKind = ChartKind.temperature

    private func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }

    private func gigabytes(_ bytes: Double) -> String { String(format: "%.1fG", bytes / 1_073_741_824) }

    var body: some View {
        VStack(spacing: 6) {
            PageHeader(title: L("系统监控"), model: model)
            HStack(spacing: 8) {
                readings.frame(width: 200)
                chart.frame(maxWidth: .infinity)
                processes(title: L("CPU 占用"), rows: monitor.topCPU).frame(width: 160)
                processes(title: L("内存占用"), rows: monitor.topMemory).frame(width: 160)
            }
        }
    }

    private func reading(_ title: String, _ value: String?) -> some View {
        Group {
            if let value {
                HStack {
                    Text(title).foregroundStyle(Theme.secondary)
                    Spacer()
                    Text(value).monospacedDigit().lineLimit(1)
                }
                .font(.system(size: 12))
            }
        }
    }

    private var readings: some View {
        Card {
            VStack(spacing: 6) {
                reading("CPU", formatTemperature(monitor.cpuTemp))
                reading("GPU", formatTemperature(monitor.gpuTemp))
                reading(L("电池"), formatTemperature(monitor.batteryTemp))
                reading(L("固态硬盘"), formatTemperature(monitor.ssdTemp))
                ForEach(monitor.fans.indices, id: \.self) { index in
                    reading(monitor.fans.count > 1 ? L("风扇 %d", index + 1) : L("风扇"), "\(monitor.fans[index]) rpm")
                }
                reading(L("整机功耗"), monitor.power.map { String(format: "%.1f W", $0) })
                reading(L("网速"), "↓ \(formatSpeed(monitor.downloadSpeed))  ↑ \(formatSpeed(monitor.uploadSpeed))")
            }
        }
    }

    private func chartTab(_ kind: ChartKind) -> some View {
        Button { chartKind = kind } label: {
            Text(kind.title)
                .foregroundStyle(chartKind == kind ? Theme.blue : Theme.secondary)
                .padding(.horizontal, 7)
                .frame(height: 18)
                .capsuleFill(chartKind == kind ? Theme.blue.opacity(0.16) : Color.clear)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var chartDetail: some View {
        switch chartKind {
        case .temperature:
            legend("CPU", Theme.blue)
            legend("GPU", Theme.purple)
        case .cpu:
            Text(L("用户 %@  系统 %@", percent(monitor.cpuUser), percent(monitor.cpuSystem)))
                .foregroundStyle(Theme.secondary)
                .monospacedDigit()
        case .memory:
            let total = Double(ProcessInfo.processInfo.physicalMemory)
            Text(L("已用 %@/%@  Swap %@", gigabytes(monitor.memory * total), gigabytes(total), gigabytes(Double(monitor.swapUsed))))
                .foregroundStyle(Theme.secondary)
                .monospacedDigit()
                .lineLimit(1)
        }
    }

    @ViewBuilder private var activeChart: some View {
        switch chartKind {
        case .temperature:
            HistoryChart(samples: monitor.history, series: [(\.cpu, Theme.blue), (\.gpu, Theme.purple)], range: 30...110, grid: [40, 70, 100], unit: "°")
        case .cpu:
            HistoryChart(samples: monitor.history, series: [(\.cpuLoad, Theme.blue)], range: 0...100, grid: [0, 50, 100], unit: "%", filled: true)
        case .memory:
            HistoryChart(samples: monitor.history, series: [(\.memory, Theme.orange)], range: 0...100, grid: [0, 50, 100], unit: "%", filled: true)
        }
    }

    private var chart: some View {
        Card {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    ForEach(ChartKind.allCases, id: \.self) { chartTab($0) }
                    Spacer(minLength: 4)
                    chartDetail
                }
                .font(.system(size: 11, weight: .medium))
                activeChart
            }
        }
    }

    private func legend(_ title: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Capsule().fill(color).frame(width: 10, height: 3)
            Text(title).foregroundStyle(Theme.secondary)
        }
    }

    private func processes(title: String, rows: [ProcessUsage]) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondary)
                ForEach(rows) { row in
                    HStack(spacing: 6) {
                        Text(row.name).lineLimit(1)
                        Spacer(minLength: 0)
                        Text(row.value).monospacedDigit().foregroundStyle(Theme.secondary)
                    }
                    .font(.system(size: 12))
                }
            }
        }
    }
}

struct HistoryChart: View {
    let samples: [TempSample]
    let series: [(KeyPath<TempSample, Double?>, Color)]
    let range: ClosedRange<Double>
    let grid: [Double]
    let unit: String
    var filled = false
    private let window = 600.0

    var body: some View {
        Canvas { context, size in
            let plotWidth = size.width - 30
            for value in grid {
                let y = yPosition(value, height: size.height)
                var line = Path()
                line.move(to: CGPoint(x: 0, y: y))
                line.addLine(to: CGPoint(x: plotWidth, y: y))
                context.stroke(line, with: .color(Theme.hairline), lineWidth: 1)
                context.draw(
                    Text("\(Int(value))\(unit)").font(.system(size: 10)).foregroundStyle(Theme.tertiary),
                    at: CGPoint(x: plotWidth + 4, y: min(max(y, 7), size.height - 7)),
                    anchor: .leading
                )
            }
            let now = Date()
            for (keyPath, color) in series {
                draw(keyPath, color: color, now: now, width: plotWidth, height: size.height, in: context)
            }
        }
    }

    private func yPosition(_ value: Double, height: CGFloat) -> CGFloat {
        let fraction = (min(max(value, range.lowerBound), range.upperBound) - range.lowerBound) / (range.upperBound - range.lowerBound)
        return height * (1 - fraction)
    }

    private func draw(_ keyPath: KeyPath<TempSample, Double?>, color: Color, now: Date, width: CGFloat, height: CGFloat, in context: GraphicsContext) {
        var points: [CGPoint] = []
        for sample in samples {
            guard let value = sample[keyPath: keyPath] else { continue }
            let age = now.timeIntervalSince(sample.time)
            points.append(CGPoint(x: width * (1 - age / window), y: yPosition(value, height: height)))
        }
        guard let first = points.first, let last = points.last else { return }
        var path = Path()
        path.addLines(points)
        if filled {
            var area = path
            area.addLine(to: CGPoint(x: last.x, y: height))
            area.addLine(to: CGPoint(x: first.x, y: height))
            area.closeSubpath()
            context.fill(area, with: .linearGradient(
                Gradient(colors: [color.opacity(0.32), color.opacity(0.03)]),
                startPoint: .zero,
                endPoint: CGPoint(x: 0, y: height)
            ))
        }
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
    }
}
