import Foundation

/// 按 App 里选的语言格式化日期；template 是 yMMMM 这样的模板，系统会按语言排好顺序。
func localizedDateFormatter(_ template: String? = nil) -> DateFormatter {
    let formatter = DateFormatter()
    formatter.locale = LanguageStore.shared.locale
    if let template { formatter.setLocalizedDateFormatFromTemplate(template) }
    return formatter
}

/// 文字语言跟随 App 设置，12 或 24 小时制跟随系统设置。
func formatClockTime(_ date: Date) -> String {
    // 小时字段 h、K 表示 12 小时制。不能靠有没有 a 判断：中文的时段字段是 B；引号里的文字也要先去掉，法语格式会写成 HH 'h'。
    let pattern = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? ""
    let uses12Hour = pattern.replacingOccurrences(of: "'[^']*'", with: "", options: .regularExpression).contains { $0 == "h" || $0 == "K" }
    return localizedDateFormatter(uses12Hour ? "hm" : "Hm").string(from: date)
}

func formatTemperature(_ value: Double?) -> String? {
    value.map { "\(Int($0.rounded()))°C" }
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

func formatDuration(minutes: Int) -> String {
    if minutes < 60 { return L("%d 分钟", minutes) }
    return minutes % 60 == 0 ? L("%d 小时", minutes / 60) : L("%d 小时 %d 分钟", minutes / 60, minutes % 60)
}

/// 菜单栏空间有限，用 42m、3h12m 这样的短格式。
func formatCompactDuration(minutes: Int) -> String {
    if minutes < 60 { return "\(minutes)m" }
    return minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h\(minutes % 60)m"
}

func relativeTime(_ date: Date) -> String {
    let seconds = Int(Date().timeIntervalSince(date))
    if seconds < 60 { return L("刚刚") }
    if seconds < 3600 { return L("%d 分钟前", seconds / 60) }
    if seconds < 86400 { return L("%d 小时前", seconds / 3600) }
    return L("%d 天前", seconds / 86400)
}
