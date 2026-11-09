import AppKit
import ServiceManagement
import SwiftUI

enum AppearanceMode: String, CaseIterable, Identifiable {
    case light, dark, system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light: return L("浅色")
        case .dark: return L("深色")
        case .system: return L("跟随系统")
        }
    }

    /// 返回 nil 时窗口跟随系统外观。
    var nsAppearance: NSAppearance? {
        switch self {
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        case .system: return nil
        }
    }
}

final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard

    @Published var overheatThreshold: Double {
        didSet { defaults.set(overheatThreshold, forKey: "overheatThreshold") }
    }
    @Published var appearance: AppearanceMode {
        didSet { defaults.set(appearance.rawValue, forKey: "appAppearance") }
    }
    @Published var showMenuBarTemperature: Bool {
        didSet { defaults.set(showMenuBarTemperature, forKey: "showMenuBarTemperature") }
    }
    @Published var showMenuBarCPU: Bool {
        didSet { defaults.set(showMenuBarCPU, forKey: "showMenuBarCPU") }
    }
    @Published var showMenuBarNetwork: Bool {
        didSet { defaults.set(showMenuBarNetwork, forKey: "showMenuBarNetwork") }
    }
    @Published var showMenuBarBattery: Bool {
        didSet { defaults.set(showMenuBarBattery, forKey: "showMenuBarBattery") }
    }
    @Published var launchError: String?

    private init() {
        overheatThreshold = defaults.object(forKey: "overheatThreshold") as? Double ?? 90
        showMenuBarTemperature = defaults.object(forKey: "showMenuBarTemperature") as? Bool ?? true
        showMenuBarCPU = defaults.bool(forKey: "showMenuBarCPU")
        showMenuBarNetwork = defaults.bool(forKey: "showMenuBarNetwork")
        showMenuBarBattery = defaults.bool(forKey: "showMenuBarBattery")
        appearance = defaults.string(forKey: "appAppearance").flatMap(AppearanceMode.init(rawValue:)) ?? .light
    }

    var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    func setLaunchAtLogin(_ enabled: Bool) {
        objectWillChange.send()
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchError = nil
        } catch {
            launchError = L("设置失败：%@", error.localizedDescription)
        }
    }
}
