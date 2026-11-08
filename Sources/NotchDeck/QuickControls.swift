import AppKit
import CoreBluetooth
import CoreWLAN
import IOKit.pwr_mgt
import SwiftUI

/// 这些开关大多没有公开接口，只能动态调用系统私有函数；函数不存在时对应开关显示为不可用。
private func systemFunction<T>(_ path: String, _ name: String, as type: T.Type) -> T? {
    guard let handle = dlopen(path, RTLD_LAZY), let symbol = dlsym(handle, name) else { return nil }
    return unsafeBitCast(symbol, to: type)
}

private let bluetoothPath = "/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth"
private let skyLightPath = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
private let displayServicesPath = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
private let loginPath = "/System/Library/PrivateFrameworks/login.framework/login"

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
    @Published private(set) var muted: Bool?
    @Published var volume: Float?
    @Published var brightness: Float?
    @Published private(set) var bluetoothDevices: [BluetoothDeviceInfo] = []

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
            let devices = Self.parseBluetoothDevices(Self.readBluetoothProfile())
            DispatchQueue.main.async { self.bluetoothDevices = devices }
        }
    }

    private static func readBluetoothProfile() -> Data {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return Data() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return data
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
        if keepAwake {
            IOPMAssertionRelease(awakeAssertion)
            keepAwake = false
        } else {
            let status = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "NotchDeck 防止休眠" as CFString,
                &awakeAssertion
            )
            keepAwake = status == kIOReturnSuccess
        }
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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["displaysleepnow"]
        try? process.run()
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
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).cardFill(hovering && enabled ? Color.white.opacity(0.9) : Theme.card))
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

    private let refreshTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private func state(_ value: Bool?) -> String {
        guard let value else { return "不可用" }
        return value ? "已开启" : "已关闭"
    }

    private var bluetoothSubtitle: String {
        switch controls.bluetoothAuthorization {
        case .allowedAlways: return state(controls.bluetooth)
        case .notDetermined: return "点击授权"
        default: return "去系统设置授权"
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
                Text(title).font(.system(size: 10)).foregroundStyle(Theme.secondary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var bluetoothRow: some View {
        if controls.bluetoothDevices.isEmpty {
            Text(controls.bluetoothAuthorization == .allowedAlways ? "没有已连接的蓝牙设备" : "授权蓝牙后显示设备电量")
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
                        .help(device.battery.map { "\(device.name)：\($0)" } ?? "\(device.name)：设备未提供电量")
                    }
                }
            }
            .scrollIndicators(.never)
            .frame(height: 22)
        }
    }

    private var tiles: some View {
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                ToggleTile(title: "Wi-Fi", symbol: "wifi", isOn: controls.wifi == true, subtitle: state(controls.wifi), enabled: controls.wifi != nil) { controls.toggleWiFi() }
                ToggleTile(title: "蓝牙", symbol: "dot.radiowaves.left.and.right", isOn: controls.bluetooth == true, subtitle: bluetoothSubtitle) { controls.toggleBluetooth() }
                ToggleTile(title: "深色模式", symbol: "circle.lefthalf.filled", isOn: controls.darkMode == true, subtitle: state(controls.darkMode), enabled: controls.darkMode != nil) { controls.toggleDarkMode() }
            }
            GridRow {
                ToggleTile(title: "夜览", symbol: "sun.max", isOn: controls.nightShift == true, subtitle: state(controls.nightShift), enabled: controls.nightShift != nil) { controls.toggleNightShift() }
                ToggleTile(title: "防止休眠", symbol: "cup.and.saucer", isOn: controls.keepAwake, subtitle: state(controls.keepAwake)) { controls.toggleKeepAwake() }
                ToggleTile(title: "静音", symbol: "speaker.slash", isOn: controls.muted == true, subtitle: state(controls.muted), enabled: controls.muted != nil) { controls.toggleMute() }
            }
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            PageHeader(title: "快捷开关", model: model)
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
                            action("截图", "camera.viewfinder") {
                                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Screenshot.app"))
                            }
                            action("息屏", "moon.fill") { controls.sleepDisplay() }
                            action("锁屏", "lock.fill") { controls.lockScreen() }
                            action("设置", "gearshape") {
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
