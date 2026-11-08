import Foundation
import IOKit
import IOKit.ps

struct TempSample {
    let time: Date
    let cpu: Double?
    let gpu: Double?
    /// CPU 和内存占用，单位是百分比。
    let cpuLoad: Double?
    let memory: Double?
}

struct ProcessUsage: Identifiable {
    var id: String { name + value }
    let name: String
    let value: String
}

final class SystemMonitor: ObservableObject {
    static let shared = SystemMonitor()
    enum Mode { case collapsed, expanded, detail }

    @Published private(set) var cpu = 0.0
    @Published private(set) var cpuUser = 0.0
    @Published private(set) var cpuSystem = 0.0
    @Published private(set) var gpu = 0.0
    @Published private(set) var memory = 0.0
    @Published private(set) var memoryPressure = "压力低"
    @Published private(set) var swapUsed: UInt64 = 0
    @Published private(set) var downloadSpeed = 0.0
    @Published private(set) var uploadSpeed = 0.0
    @Published private(set) var diskUsed: Int64 = 0
    @Published private(set) var diskTotal: Int64 = 0
    @Published private(set) var cpuTemp: Double?
    @Published private(set) var gpuTemp: Double?
    @Published private(set) var batteryTemp: Double?
    @Published private(set) var ssdTemp: Double?
    @Published private(set) var power: Double?
    @Published private(set) var fans: [Int] = []
    @Published private(set) var history: [TempSample] = []
    @Published private(set) var topCPU: [ProcessUsage] = []
    @Published private(set) var topMemory: [ProcessUsage] = []
    @Published private(set) var batteryPercent: Int?
    @Published private(set) var isCharging = false
    @Published private(set) var onExternalPower = false

    private let queue = DispatchQueue(label: "notchdeck.monitor", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var mode = Mode.collapsed
    private var smc: SMC?
    private var hid: HIDSensors?
    private var lastTicks: (user: UInt64, system: UInt64, total: UInt64)?
    private var lastLoad = (user: 0.0, system: 0.0)
    private var lastNetwork: [String: (received: UInt32, sent: UInt32)] = [:]
    private var lastNetworkTime: TimeInterval?
    private var hotCount = 0
    private var lastOverheatAlert = Date.distantPast
    private var knownExternalPower: Bool?

    func start() {
        queue.async {
            self.smc = SMC()
            self.hid = HIDSensors()
        }
        readPower(announce: false)
        let source = IOPSNotificationCreateRunLoopSource({ _ in
            SystemMonitor.shared.readPower(announce: true)
        }, nil).takeRetainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        schedule()
    }

    func setMode(_ newMode: Mode) {
        guard newMode != mode else { return }
        mode = newMode
        schedule()
    }

    private func schedule() {
        timer?.cancel()
        let source = DispatchSource.makeTimerSource(queue: queue)
        let interval: TimeInterval = mode == .collapsed ? 10 : 2
        source.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(200))
        source.setEventHandler { [weak self] in self?.sample() }
        source.resume()
        timer = source
    }

    /// CPU、内存和网速在面板收起时也采样，这样打开监控页时已经有历史曲线。
    private func sample() {
        let load = readCPU()
        let memoryValue = readMemory()
        let swap = readSwap()
        let network = readNetwork()
        DispatchQueue.main.async {
            self.cpu = load.user + load.system
            self.cpuUser = load.user
            self.cpuSystem = load.system
            self.memory = memoryValue
            self.swapUsed = swap
            self.downloadSpeed = network.download
            self.uploadSpeed = network.upload
        }
        sampleTemperature(cpuLoad: (load.user + load.system) * 100, memory: memoryValue * 100)
        guard mode != .collapsed else { return }
        sampleLoads()
        if mode == .detail { sampleDetail() }
    }

    private func sampleTemperature(cpuLoad: Double, memory: Double) {
        var cpuValue: Double?
        var gpuValue: Double?
        if let smc {
            cpuValue = smc.maxTemperature(smc.cpuKeys)
            gpuValue = smc.maxTemperature(smc.gpuKeys)
        }
        if cpuValue == nil { cpuValue = hid?.maxTemperature { $0.hasPrefix("PMU") && $0.contains("tdie") } }
        let battery = hid?.maxTemperature { $0 == "gas gauge battery" }
        let ssd = hid?.maxTemperature { $0.hasPrefix("NAND") }
        let watt = smc?.systemPower
        let fanValues = (0..<(smc?.fanCount ?? 0)).compactMap { smc?.fanSpeed($0).map { Int($0) } }

        DispatchQueue.main.async {
            self.cpuTemp = cpuValue
            self.gpuTemp = gpuValue
            self.batteryTemp = battery
            self.ssdTemp = ssd
            self.power = watt
            self.fans = fanValues
            let now = Date()
            self.history.append(TempSample(time: now, cpu: cpuValue, gpu: gpuValue, cpuLoad: cpuLoad, memory: memory))
            self.history.removeAll { now.timeIntervalSince($0.time) > 600 }
            self.checkOverheat(cpuValue)
        }
    }

    private func checkOverheat(_ value: Double?) {
        guard let value, value >= AppSettings.shared.overheatThreshold else { hotCount = 0; return }
        hotCount += 1
        guard hotCount >= 3, Date().timeIntervalSince(lastOverheatAlert) > 300 else { return }
        lastOverheatAlert = Date()
        Toasts.shared.show("CPU \(Int(value.rounded()))°C", icon: "thermometer.high")
    }

    private func sampleLoads() {
        let gpuValue = readGPU()
        let pressure = readPressure()
        let disk = readDisk()
        DispatchQueue.main.async {
            self.gpu = gpuValue
            self.memoryPressure = pressure
            self.diskUsed = disk.used
            self.diskTotal = disk.total
        }
    }

    private func readCPU() -> (user: Double, system: Double) {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return lastLoad }
        let user = UInt64(info.cpu_ticks.0) + UInt64(info.cpu_ticks.3)
        let system = UInt64(info.cpu_ticks.1)
        let total = user + system + UInt64(info.cpu_ticks.2)
        // 切换采样频率时两次读取可能隔得很近，样本太少时沿用上一次的结果，避免曲线抖动。
        if let last = lastTicks, total < last.total + 20 { return lastLoad }
        defer { lastTicks = (user, system, total) }
        guard let last = lastTicks else { return lastLoad }
        let elapsed = Double(total - last.total)
        lastLoad = (Double(user - last.user) / elapsed, Double(system - last.system) / elapsed)
        return lastLoad
    }

    private func readSwap() -> UInt64 {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return 0 }
        return usage.xsu_used
    }

    /// 只统计物理网卡 en*。代理或 VPN 的虚拟网卡 utun* 走的也是同一份流量，算进去会重复。
    private func readNetwork() -> (download: Double, upload: Double) {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return (0, 0) }
        defer { freeifaddrs(head) }

        var current: [String: (received: UInt32, sent: UInt32)] = [:]
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let name = String(cString: entry.pointee.ifa_name)
            guard name.hasPrefix("en"),
                  entry.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK),
                  let data = entry.pointee.ifa_data?.assumingMemoryBound(to: if_data.self) else { continue }
            current[name] = (data.pointee.ifi_ibytes, data.pointee.ifi_obytes)
        }

        let now = ProcessInfo.processInfo.systemUptime
        defer {
            lastNetwork = current
            lastNetworkTime = now
        }
        guard let lastTime = lastNetworkTime, now > lastTime else { return (0, 0) }
        var received: UInt64 = 0
        var sent: UInt64 = 0
        for (name, value) in current {
            guard let previous = lastNetwork[name] else { continue }
            // 系统的计数器是 32 位，到 4GB 会回绕，用溢出减法才能得到正确差值。
            received += UInt64(value.received &- previous.received)
            sent += UInt64(value.sent &- previous.sent)
        }
        let elapsed = now - lastTime
        return (Double(received) / elapsed, Double(sent) / elapsed)
    }

    private func readGPU() -> Double {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return 0 }
        defer { IOObjectRelease(iterator) }
        var value = 0.0
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            var properties: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(entry, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dictionary = properties?.takeRetainedValue() as? [String: Any],
               let stats = dictionary["PerformanceStatistics"] as? [String: Any],
               let utilization = stats["Device Utilization %"] as? Double {
                value = max(value, utilization / 100)
            }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
        return value
    }

    private func readMemory() -> Double {
        var info = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let pages = Double(info.internal_page_count) - Double(info.purgeable_count) + Double(info.wire_count) + Double(info.compressor_page_count)
        return min(pages * Double(vm_kernel_page_size) / Double(ProcessInfo.processInfo.physicalMemory), 1)
    }

    private func readPressure() -> String {
        var level: Int32 = 1
        var size = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0)
        switch level {
        case 4: return "压力高"
        case 2: return "压力中"
        default: return "压力低"
        }
    }

    private func readDisk() -> (used: Int64, total: Int64) {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity,
              let free = values.volumeAvailableCapacityForImportantUsage else { return (0, 0) }
        return (Int64(total) - free, Int64(total))
    }

    private func sampleDetail() {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-Aceo", "pcpu=,rss=,comm="]
        // 没有 UTF-8 语言环境时，ps 会把中文进程名转义成 M-e... 的形式。
        process.environment = ["LC_ALL": "en_US.UTF-8"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()

        let rows: [(cpu: Double, rss: Double, name: String)] = output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let cpu = Double(parts[0]), let rss = Double(parts[1]) else { return nil }
            return (cpu, rss, String(parts[2]))
        }
        let byCPU = rows.sorted { $0.cpu > $1.cpu }.prefix(5).map { ProcessUsage(name: $0.name, value: String(format: "%.0f%%", $0.cpu)) }
        let byMemory = rows.sorted { $0.rss > $1.rss }.prefix(5).map { row -> ProcessUsage in
            let gigabytes = row.rss / 1_048_576
            let value = gigabytes >= 1 ? String(format: "%.1fG", gigabytes) : String(format: "%.0fM", row.rss / 1024)
            return ProcessUsage(name: row.name, value: value)
        }
        DispatchQueue.main.async {
            self.topCPU = Array(byCPU)
            self.topMemory = Array(byMemory)
        }
    }

    func readPower(announce: Bool) {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef],
              let first = list.first,
              let description = IOPSGetPowerSourceDescription(blob, first)?.takeUnretainedValue() as? [String: Any] else { return }
        let current = description["Current Capacity"] as? Int ?? 0
        let maximum = description["Max Capacity"] as? Int ?? 100
        let percent = maximum > 0 ? current * 100 / maximum : current
        let charging = description["Is Charging"] as? Bool ?? false
        let external = (description["Power Source State"] as? String) == "AC Power"
        batteryPercent = percent
        isCharging = charging
        onExternalPower = external
        if announce, let known = knownExternalPower, known != external {
            Toasts.shared.show(external ? "已接电源 \(percent)%" : "使用电池 \(percent)%", icon: external ? "bolt.fill" : "battery.75percent")
        }
        knownExternalPower = external
    }
}
