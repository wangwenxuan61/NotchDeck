import AppKit
import SwiftUI

struct PageHeader<Trailing: View>: View {
    let title: String
    let model: PanelModel
    var backTo: Page = .home
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 6) {
            Button { model.page = backTo } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                    Text(title)
                }
                .font(.system(size: 13, weight: .semibold))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer()
            trailing
        }
        .frame(height: 20)
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: String, model: PanelModel) {
        self.init(title: title, model: model) { EmptyView() }
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
    private enum ChartKind: String, CaseIterable {
        case temperature = "温度", cpu = "CPU", memory = "内存"
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
            Text(L(kind.rawValue))
                .foregroundStyle(chartKind == kind ? Theme.blue : Theme.secondary)
                .padding(.horizontal, 7)
                .frame(height: 18)
                .background(Capsule().fill(chartKind == kind ? Theme.blue.opacity(0.16) : Color.clear))
                .contentShape(Capsule())
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

struct AllAppsPage: View {
    @ObservedObject var model: PanelModel
    @ObservedObject private var store = DockStore.shared

    private func collapse() {
        AppDelegate.shared.closePanel()
    }

    var body: some View {
        VStack(spacing: 6) {
            PageHeader(title: L("所有应用"), model: model)
            ScrollView(.vertical) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 11), spacing: 10) {
                    ForEach(store.allApps) { app in
                        VStack(spacing: 3) {
                            AppIcon(app: app, size: 40) { collapse() }
                            Text(app.name).font(.system(size: 10)).lineLimit(1)
                        }
                        .contextMenu {
                            if store.paths.contains(app.path) {
                                Button(L("从快捷栏移除")) { store.unpin(app.path) }
                            } else {
                                Button(L("固定到快捷栏")) { store.pin(app.path) }
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.never)
        }
        .onAppear { store.refreshAllApps() }
    }
}

struct PinnedAppsPage: View {
    @ObservedObject var model: PanelModel
    @ObservedObject private var store = DockStore.shared

    private func collapse() {
        AppDelegate.shared.closePanel()
    }

    var body: some View {
        VStack(spacing: 6) {
            PageHeader(title: L("快捷栏"), model: model) {
                Button {
                    if let url = AppDelegate.shared.pickApplication() { store.pin(url.path) }
                } label: {
                    Label(L("添加 App"), systemImage: "plus").font(.system(size: 12))
                }
                .buttonStyle(.plain)
            }
            ScrollView(.vertical) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 11), spacing: 10) {
                    ForEach(store.items) { app in
                        VStack(spacing: 3) {
                            AppIcon(app: app, size: 40) { collapse() }
                            Text(app.name).font(.system(size: 10)).lineLimit(1)
                        }
                        .contextMenu { Button(L("从快捷栏移除")) { store.unpin(app.path) } }
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.never)
        }
    }
}

struct SettingsPage: View {
    @ObservedObject var model: PanelModel
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var reminders = ReminderSync.shared
    @ObservedObject private var busy = LookBusyController.shared
    @ObservedObject private var language = LanguageStore.shared
    @ObservedObject private var updates = UpdateChecker.shared

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(title).font(.system(size: 13)).lineLimit(1)
            Spacer(minLength: 8)
            content()
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            PageHeader(title: L("设置"), model: model) {
                HStack(spacing: 12) {
                    Text(L("⌥⌘N 面板  ·  ⌃⌥V 剪贴板  ·  ⌃⌥B 装忙"))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondary)
                    Button(L("退出 NotchDeck")) { NSApp.terminate(nil) }.controlSize(.small)
                }
            }
            Card(padding: 10) {
                HStack(alignment: .top, spacing: 24) {
                    generalColumn.frame(maxWidth: .infinity)
                    integrationColumn.frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func toggle(_ isOn: Binding<Bool>) -> some View {
        Toggle("", isOn: isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
    }

    private func menuBarChip(_ title: String, _ isOn: Binding<Bool>) -> some View {
        Button { isOn.wrappedValue.toggle() } label: {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(isOn.wrappedValue ? Color.white : Theme.primary)
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background(Capsule().fill(isOn.wrappedValue ? Theme.blue : Theme.control))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var generalColumn: some View {
        VStack(spacing: 8) {
            row(L("语言")) {
                Picker("", selection: $language.selection) {
                    ForEach(AppLanguage.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }
            row(L("外观")) {
                Picker("", selection: $settings.appearance) {
                    ForEach(AppearanceMode.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }
            row(L("开机自动启动")) {
                toggle(Binding(get: { settings.launchAtLogin }, set: { settings.setLaunchAtLogin($0) }))
            }
            if let error = settings.launchError {
                Text(error).font(.system(size: 11)).foregroundStyle(Theme.coral).frame(maxWidth: .infinity, alignment: .leading)
            }
            row(L("菜单栏显示")) {
                HStack(spacing: 4) {
                    menuBarChip(L("温度"), $settings.showMenuBarTemperature)
                    menuBarChip("CPU", $settings.showMenuBarCPU)
                    menuBarChip(L("网速"), $settings.showMenuBarNetwork)
                    menuBarChip(L("电池"), $settings.showMenuBarBattery)
                }
            }
        }
    }

    private var integrationColumn: some View {
        VStack(spacing: 8) {
            row(L("CPU 过热提醒：%d°C", Int(settings.overheatThreshold))) {
                Slider(value: $settings.overheatThreshold, in: 70...105, step: 5).frame(width: 130).controlSize(.small)
            }
            row(L("同步系统提醒事项")) {
                HStack(spacing: 8) {
                    if reminders.isActive {
                        Picker("", selection: $reminders.selectedListID) {
                            ForEach(reminders.lists, id: \.calendarIdentifier) { list in
                                Text(list.title).tag(list.calendarIdentifier)
                            }
                        }
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(width: 120)
                    }
                    toggle(Binding(get: { reminders.isActive }, set: { reminders.setEnabled($0) }))
                }
            }
            row(L("装忙用的文件名")) {
                HStack(spacing: 8) {
                    Text(busy.usesCustomProject ? busy.project.name : L("演示项目"))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                    if busy.usesCustomProject {
                        Button(L("恢复演示")) { busy.useDemoProject() }.controlSize(.small)
                    }
                    Button(L("选择文件夹")) { busy.chooseProject() }.controlSize(.small)
                }
            }
            row(L("首页卡片")) {
                Button(L("自定义")) { model.page = .customize }.controlSize(.small)
            }
            row(L("自动检查更新")) {
                HStack(spacing: 8) {
                    Text(verbatim: "v\(updates.currentVersion)")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                        .monospacedDigit()
                    if let latest = updates.latestVersion {
                        Button(L("更新到 %@", latest)) { updates.openDownloadPage() }
                            .controlSize(.small)
                            .keyboardShortcut(.defaultAction)
                    } else {
                        Button(updates.isChecking ? L("检查中…") : L("检查更新")) { updates.check(userInitiated: true) }
                            .controlSize(.small)
                            .disabled(updates.isChecking)
                    }
                    toggle($updates.autoCheck)
                }
            }
        }
    }
}
