import Foundation

/// 设置里可选的语言。要新增语言：在这里加一项，在 Translations 目录加一个翻译文件，并登记到下面的 translations。
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case english = "en"
    case japanese = "ja"
    case korean = "ko"
    case french = "fr"
    case german = "de"
    case spanish = "es"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return L("跟随系统")
        case .simplifiedChinese: return "简体中文"
        case .traditionalChinese: return "繁體中文"
        case .english: return "English"
        case .japanese: return "日本語"
        case .korean: return "한국어"
        case .french: return "Français"
        case .german: return "Deutsch"
        case .spanish: return "Español"
        }
    }
}

final class LanguageStore: ObservableObject {
    static let shared = LanguageStore()
    private static let key = "appLanguage"

    @Published var selection: AppLanguage {
        didSet {
            UserDefaults.standard.set(selection.rawValue, forKey: Self.key)
            current = Self.resolve(selection)
        }
    }
    /// 实际使用的语言，不会是 `.system`。
    @Published private(set) var current: AppLanguage

    var locale: Locale { Locale(identifier: current.rawValue) }

    private init() {
        let saved = UserDefaults.standard.string(forKey: Self.key).flatMap(AppLanguage.init(rawValue:)) ?? .system
        selection = saved
        current = Self.resolve(saved)
    }

    private static func resolve(_ language: AppLanguage) -> AppLanguage {
        guard language == .system else { return language }
        let preferred = Locale.preferredLanguages.first ?? "en"
        if preferred.hasPrefix("zh") {
            let traditional = ["zh-Hant", "zh-TW", "zh-HK", "zh-MO"].contains { preferred.hasPrefix($0) }
            return traditional ? .traditionalChinese : .simplifiedChinese
        }
        return AppLanguage.allCases.first { $0 != .system && preferred.hasPrefix($0.rawValue) } ?? .english
    }
}

/// 以简体中文原文作为 key 查翻译；查不到时显示原文。
func L(_ key: String, _ arguments: CVarArg...) -> String {
    let text = translations[LanguageStore.shared.current]?[key] ?? key
    return arguments.isEmpty ? text : String(format: text, arguments: arguments)
}

private let translations: [AppLanguage: [String: String]] = [
    .traditionalChinese: traditionalChineseStrings,
    .english: englishStrings,
    .japanese: japaneseStrings,
    .korean: koreanStrings,
    .french: frenchStrings,
    .german: germanStrings,
    .spanish: spanishStrings,
]
