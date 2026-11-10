import AppKit
import CoreAudio
import CoreBluetooth
import CoreWLAN
import IOKit.pwr_mgt
import SwiftUI

private let bluetoothPath = "/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth"
private let skyLightPath = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
private let displayServicesPath = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
private let loginPath = "/System/Library/PrivateFrameworks/login.framework/login"

func formatDuration(minutes: Int) -> String {
    if minutes < 60 { return L("%d 分钟", minutes) }
    return minutes % 60 == 0 ? L("%d 小时", minutes / 60) : L("%d 小时 %d 分钟", minutes / 60, minutes % 60)
}

/// 菜单栏空间有限，用 42m、3h12m 这样的短格式。
func formatCompactDuration(minutes: Int) -> String {
    if minutes < 60 { return "\(minutes)m" }
    return minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h\(minutes % 60)m"
}

struct BluetoothDeviceInfo: Identifiable {
    var id: String { name }
    let name: String
    let symbol: String
    let battery: String?
}

final class QuickControls: ObservableObject {
    static let shared = QuickControls()

    @Published private(set) var wifi: Bool?
    @Published private(set) var bluetooth: Bool?
    @Published private(set) var bluetoothAuthorization = CBManager.authorization
    @Published private(set) var darkMode: Bool?
    @Published private(set) var nightShift: Bool?
    @Published private(set) var keepAwake = false
    /// 定时防止休眠选的时长（分钟），一直开着时为 nil。
    @Published private(set) var keepAwakeDuration: Int?
    /// 剩余分钟数，向上取整；一直开着或已关闭时为 nil。
    @Published private(set) var keepAwakeMinutesLeft: Int?
    static let keepAwakeDurations = [15, 30, 45, 60, 240, 480, 720]
    private var keepAwakeEnd: Date?
    private var keepAwakeTimer: Timer?
    @Published private(set) var muted: Bool?
    @Published var volume: Float?
    @Published var brightness: Float?
    @Published private(set) var bluetoothDevices: [BluetoothDeviceInfo] = []
    @Published private(set) var outputs: [AudioOutput] = []
    @Published private(set) var currentOutput: AudioObjectID?

    private var lastDeviceRefresh = Date.distantPast
    private var bluetoothRequester: CBCentralManager?
    private var awakeAssertion: IOPMAssertionID = 0
    private let blueLightClient: NSObject? = {
        _ = dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY)
        return (NSClassFromString("CBBlueLightClient") as? NSObject.Type)?.init()
    }()

    private typealias GetInt = @convention(c) () -> Int32
    private typealias SetInt = @convention(c) (Int32) -> Int32
    private typealias SetBool = @convention(c) (Bool) -> Void
    private typealias GetBrightness = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (UInt32, Float) -> Int32

    private var builtInDisplay: UInt32? {
        NSScreen.screens.compactMap {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        }.first { CGDisplayIsBuiltin($0) != 0 }
    }

    func refresh() {
        wifi = CWWiFiClient.shared().interface()?.powerOn()

        bluetoothAuthorization = CBManager.authorization
        // 未获授权时读取蓝牙状态会让系统直接终止 App，必须先检查。
        if bluetoothAuthorization == .allowedAlways,
           let get = systemFunction(bluetoothPath, "IOBluetoothPreferenceGetControllerPowerState", as: GetInt.self) {
            bluetooth = get() == 1
        } else {
            bluetooth = nil
        }
        refreshBluetoothDevices()

        darkMode = systemFunction(skyLightPath, "SLSGetAppearanceThemeLegacy", as: GetInt.self).map { $0() != 0 }
        nightShift = readNightShift()
        muted = SystemVolume.isMuted()
        volume = SystemVolume.get()
        // 列表没变时不重新赋值，避免下拉菜单展开时被刷新。
        let devices = SystemVolume.outputDevices()
        if devices != outputs { outputs = devices }
        let current = SystemVolume.outputDevice()
        if current != currentOutput { currentOutput = current }

        if let display = builtInDisplay, let get = systemFunction(displayServicesPath, "DisplayServicesGetBrightness", as: GetBrightness.self) {
            var value: Float = 0
            brightness = get(display, &value) == 0 ? value : nil
        } else {
            brightness = nil
        }
    }

    /// 设备电量变化很慢，30 秒读一次；只在授权蓝牙后读取，避免打开页面就弹权限窗口。
    private func refreshBluetoothDevices() {
        guard Date().timeIntervalSince(lastDeviceRefresh) >= 30 else { return }
        guard bluetoothAuthorization == .allowedAlways else {
            bluetoothDevices = []
            return
        }
        lastDeviceRefresh = Date()
        DispatchQueue.global(qos: .utility).async {
            let profile = Shell.output("/usr/sbin/system_profiler", ["SPBluetoothDataType", "-json"]) ?? Data()
            let devices = Self.parseBluetoothDevices(profile)
            DispatchQueue.main.async { self.bluetoothDevices = devices }
        }
    }

    private static func parseBluetoothDevices(_ data: Data) -> [BluetoothDeviceInfo] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let controllers = root["SPBluetoothDataType"] as? [[String: Any]] else { return [] }
        var devices: [BluetoothDeviceInfo] = []
        for controller in controllers {
            for entry in controller["device_connected"] as? [[String: Any]] ?? [] {
                for (name, value) in entry {
                    guard let info = value as? [String: Any] else { continue }
                    func level(_ key: String) -> String? {
                        (info["device_batteryLevel\(key)"] as? String)?.replacingOccurrences(of: "%", with: "")
                    }
                    var battery: String?
                    if let left = level("Left"), let right = level("Right") {
                        battery = "L\(left) R\(right)"
                    } else if let single = level("Main") ?? level("Left") ?? level("Right") {
                        battery = "\(single)%"
                    }
                    let type = info["device_minorType"] as? String ?? ""
                    let symbol: String
                    switch type {
                    case "Keyboard": symbol = "keyboard"
                    case "Mouse": symbol = "computermouse"
                    case "Headphones", "Headset": symbol = name.localizedCaseInsensitiveContains("airpods") ? "airpodspro" : "headphones"
                    default: symbol = "dot.radiowaves.left.and.right"
                    }
                    devices.append(BluetoothDeviceInfo(name: name, symbol: symbol, battery: battery))
                }
            }
        }
        return devices.sorted { $0.name < $1.name }
    }

    private func refreshSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.refresh() }
    }

    private func readNightShift() -> Bool? {
        guard let client = blueLightClient else { return nil }
        let selector = NSSelectorFromString("getBlueLightStatus:")
        guard client.responds(to: selector) else { return nil }
        typealias Function = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer) -> Bool
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: 256, alignment: 8)
        defer { buffer.deallocate() }
        buffer.initializeMemory(as: UInt8.self, repeating: 0, count: 256)
        guard unsafeBitCast(client.method(for: selector), to: Function.self)(client, selector, buffer) else { return nil }
        return buffer.load(fromByteOffset: 1, as: UInt8.self) != 0
    }

    func toggleWiFi() {
        guard let wifi else { return }
        try? CWWiFiClient.shared().interface()?.setPower(!wifi)
        refreshSoon()
    }

    func toggleBluetooth() {
        switch CBManager.authorization {
        case .allowedAlways:
            guard let bluetooth, let set = systemFunction(bluetoothPath, "IOBluetoothPreferenceSetControllerPowerState", as: SetInt.self) else { return }
            _ = set(bluetooth ? 0 : 1)
        case .notDetermined:
            NSApp.activate(ignoringOtherApps: true)
            bluetoothRequester = CBCentralManager(delegate: nil, queue: nil)
        default:
            openPrivacyPane("Privacy_Bluetooth")
        }
        refreshSoon()
    }

    func toggleDarkMode() {
        guard let darkMode, let set = systemFunction(skyLightPath, "SLSSetAppearanceThemeLegacy", as: SetBool.self) else { return }
        set(!darkMode)
        refreshSoon()
    }

    func toggleNightShift() {
        guard let nightShift, let client = blueLightClient else { return }
        let selector = NSSelectorFromString("setEnabled:")
        guard client.responds(to: selector) else { return }
        typealias Function = @convention(c) (AnyObject, Selector, Bool) -> Bool
        _ = unsafeBitCast(client.method(for: selector), to: Function.self)(client, selector, !nightShift)
        refreshSoon()
    }

    func toggleKeepAwake() {
        keepAwake ? stopKeepAwake() : startKeepAwake(minutes: nil)
    }

    /// minutes 为 nil 表示一直开着，直到手动关闭或退出 App。已经开着时只改时长。
    func startKeepAwake(minutes: Int?) {
        if !keepAwake {
            let status = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "NotchDeck Keep Awake" as CFString,
                &awakeAssertion
            )
            guard status == kIOReturnSuccess else { return }
            keepAwake = true
        }
        keepAwakeDuration = minutes
        keepAwakeTimer?.invalidate()
        keepAwakeTimer = nil
        keepAwakeEnd = minutes.map { Date().addingTimeInterval(TimeInterval($0 * 60)) }
        guard keepAwakeEnd != nil else {
            keepAwakeMinutesLeft = nil
            return
        }
        updateKeepAwakeTime()
        // 每 5 秒检查一次：既用来刷新剩余时间，也负责到点关闭，电脑休眠醒来后会立即补上。
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.updateKeepAwakeTime() }
        RunLoop.main.add(timer, forMode: .common)
        keepAwakeTimer = timer
    }

    func stopKeepAwake() {
        keepAwakeTimer?.invalidate()
        keepAwakeTimer = nil
        keepAwakeEnd = nil
        keepAwakeDuration = nil
        keepAwakeMinutesLeft = nil
        guard keepAwake else { return }
        IOPMAssertionRelease(awakeAssertion)
        keepAwake = false
    }

    private func updateKeepAwakeTime() {
        guard let end = keepAwakeEnd else { return }
        let left = end.timeIntervalSinceNow
        guard left > 0 else {
            stopKeepAwake()
            Toasts.shared.show(L("防止休眠已结束"), icon: "cup.and.saucer")
            return
        }
        let minutes = Int((left / 60).rounded(.up))
        if minutes != keepAwakeMinutesLeft { keepAwakeMinutesLeft = minutes }
    }

    func setOutput(_ device: AudioObjectID) {
        SystemVolume.setOutputDevice(device)
        refreshSoon()
    }

    func toggleMute() {
        guard let muted else { return }
        SystemVolume.setMuted(!muted)
        refreshSoon()
    }

    func setVolume(_ value: Float) {
        volume = value
        SystemVolume.set(value)
    }

    func setBrightness(_ value: Float) {
        brightness = value
        guard let display = builtInDisplay, let set = systemFunction(displayServicesPath, "DisplayServicesSetBrightness", as: SetBrightness.self) else { return }
        _ = set(display, value)
    }

    func lockScreen() {
        typealias Lock = @convention(c) () -> Int32
        _ = systemFunction(loginPath, "SACLockScreenImmediate", as: Lock.self)?()
    }

    func sleepDisplay() {
        Shell.launch("/usr/bin/pmset", ["displaysleepnow"])
    }

    func openPrivacyPane(_ name: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(name)") {
            NSWorkspace.shared.open(url)
        }
    }
}

struct ToggleTile: View {
    let title: String
    let symbol: String
    let isOn: Bool
    let subtitle: String
    var enabled = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isOn ? Color.white : Theme.primary)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(isOn ? Theme.blue : Theme.control))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).cardFill(hovering && enabled ? Theme.cardHover : Theme.card))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.55)
        .onHover { hovering = $0 }
    }
}

struct QuickControlsPage: View {
    @ObservedObject var model: PanelModel
    @ObservedObject private var controls = QuickControls.shared
    @State private var showingKeepAwake = false

    private let refreshTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private func state(_ value: Bool?) -> String {
        guard let value else { return L("不可用") }
        return value ? L("已开启") : L("已关闭")
    }

    private var bluetoothSubtitle: String {
        switch controls.bluetoothAuthorization {
        case .allowedAlways: return state(controls.bluetooth)
        case .notDetermined: return L("点击授权")
        default: return L("去系统设置授权")
        }
    }

    private func slider(_ symbol: String, value: Float, set: @escaping (Float) -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
                .frame(width: 18)
            Slider(value: Binding(get: { Double(value) }, set: { set(Float($0)) }), in: 0...1)
                .controlSize(.small)
        }
    }

    private func action(_ title: String, _ symbol: String, perform: @escaping () -> Void) -> some View {
        Button {
            AppDelegate.shared.closePanel()
            perform()
        } label: {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Theme.control))
                Text(title).font(.system(size: 10)).foregroundStyle(Theme.secondary).lineLimit(1).minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var bluetoothRow: some View {
        if controls.bluetoothDevices.isEmpty {
            Text(controls.bluetoothAuthorization == .allowedAlways ? L("没有已连接的蓝牙设备") : L("授权蓝牙后显示设备电量"))
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondary)
                .frame(height: 22)
        } else {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(controls.bluetoothDevices) { device in
                        HStack(spacing: 4) {
                            Image(systemName: device.symbol).font(.system(size: 11))
                            Text(device.battery ?? device.name)
                                .font(.system(size: 11, weight: .medium))
                                .monospacedDigit()
                                .lineLimit(1)
                                .frame(maxWidth: 72)
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(Capsule().fill(Theme.control))
                        .help(device.battery.map { "\(device.name): \($0)" } ?? L("%@：设备未提供电量", device.name))
                    }
                }
            }
            .scrollIndicators(.never)
            .frame(height: 22)
        }
    }

    @ViewBuilder private var outputPicker: some View {
        if let current = controls.currentOutput, !controls.outputs.isEmpty {
            HStack(spacing: 4) {
                Image(systemName: "speaker.wave.2").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                Picker("", selection: Binding(get: { current }, set: { controls.setOutput($0) })) {
                    ForEach(controls.outputs) { Text($0.name).tag($0.id) }
                }
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }
        }
    }

    private var keepAwakeSubtitle: String {
        guard controls.keepAwake else { return L("已关闭") }
        return controls.keepAwakeMinutesLeft.map { L("剩余 %@", formatDuration(minutes: $0)) } ?? L("已开启")
    }

    /// 点磁贴是一直开着；右边的按钮打开和首页相同的时长面板，到时间自动关闭。
    private var keepAwakeMenu: some View {
        Button { showingKeepAwake.toggle() } label: {
            Image(systemName: "timer")
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingKeepAwake, arrowEdge: .bottom) { KeepAwakePanel() }
        .help(L("选择时长"))
    }

    private var tiles: some View {
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                ToggleTile(title: "Wi-Fi", symbol: "wifi", isOn: controls.wifi == true, subtitle: state(controls.wifi), enabled: controls.wifi != nil) { controls.toggleWiFi() }
                ToggleTile(title: L("蓝牙"), symbol: "dot.radiowaves.left.and.right", isOn: controls.bluetooth == true, subtitle: bluetoothSubtitle) { controls.toggleBluetooth() }
                ToggleTile(title: L("深色模式"), symbol: "circle.lefthalf.filled", isOn: controls.darkMode == true, subtitle: state(controls.darkMode), enabled: controls.darkMode != nil) { controls.toggleDarkMode() }
            }
            GridRow {
                ToggleTile(title: L("夜览"), symbol: "sun.max", isOn: controls.nightShift == true, subtitle: state(controls.nightShift), enabled: controls.nightShift != nil) { controls.toggleNightShift() }
                ToggleTile(title: L("防止休眠"), symbol: "cup.and.saucer", isOn: controls.keepAwake, subtitle: keepAwakeSubtitle) { controls.toggleKeepAwake() }
                    .overlay(alignment: .trailing) { keepAwakeMenu.padding(.trailing, 10) }
                ToggleTile(title: L("静音"), symbol: "speaker.slash", isOn: controls.muted == true, subtitle: state(controls.muted), enabled: controls.muted != nil) { controls.toggleMute() }
            }
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            PageHeader(title: L("快捷开关"), model: model) { outputPicker }
            HStack(spacing: 8) {
                tiles.frame(maxWidth: .infinity)
                Card {
                    VStack(spacing: 8) {
                        if let volume = controls.volume {
                            slider("speaker.wave.2.fill", value: volume) { controls.setVolume($0) }
                        }
                        if let brightness = controls.brightness {
                            slider("sun.max.fill", value: brightness) { controls.setBrightness($0) }
                        }
                        bluetoothRow
                        Spacer(minLength: 0)
                        HStack(spacing: 0) {
                            action(L("截图"), "camera.viewfinder") {
                                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Screenshot.app"))
                            }
                            action(L("息屏"), "moon.fill") { controls.sleepDisplay() }
                            action(L("锁屏"), "lock.fill") { controls.lockScreen() }
                            action(L("设置"), "gearshape") {
                                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
                            }
                        }
                    }
                }
                .frame(width: 270)
            }
        }
        .onAppear { controls.refresh() }
        .onReceive(refreshTimer) { _ in controls.refresh() }
    }
}
