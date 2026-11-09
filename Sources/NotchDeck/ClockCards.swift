import AppKit
import SwiftUI

struct ClockCard: View {
    private var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = LanguageStore.shared.locale
        formatter.setLocalizedDateFormatFromTemplate("MMMdEEE")
        return formatter
    }

    var body: some View {
        Button(action: openCalendarApp) {
            Card {
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    VStack(spacing: 6) {
                        Text(dateFormatter.string(from: timeline.date))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.secondary)
                        Text(formatClockTime(timeline.date))
                            .font(.system(size: 38, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .minimumScaleFactor(0.6)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .buttonStyle(.plain)
        .help(L("打开日历"))
    }
}

/// 文字语言跟随 App 设置，12 或 24 小时制跟随系统设置。
func formatClockTime(_ date: Date) -> String {
    // 小时字段 h、K 表示 12 小时制。不能靠有没有 a 判断：中文的时段字段是 B；引号里的文字也要先去掉，法语格式会写成 HH 'h'。
    let pattern = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? ""
    let uses12Hour = pattern.replacingOccurrences(of: "'[^']*'", with: "", options: .regularExpression).contains { $0 == "h" || $0 == "K" }
    let formatter = DateFormatter()
    formatter.locale = LanguageStore.shared.locale
    formatter.setLocalizedDateFormatFromTemplate(uses12Hour ? "hm" : "Hm")
    return formatter.string(from: date)
}

struct CalendarCard: View {
    private func monthTitle(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = LanguageStore.shared.locale
        formatter.setLocalizedDateFormatFromTemplate("yMMMM")
        return formatter.string(from: date)
    }

    private func weekdaySymbols(calendar: Calendar) -> [String] {
        let formatter = DateFormatter()
        formatter.locale = LanguageStore.shared.locale
        let symbols = formatter.veryShortStandaloneWeekdaySymbols ?? []
        let start = calendar.firstWeekday - 1
        return Array(symbols[start...] + symbols[..<start])
    }

    private func days(for date: Date, calendar: Calendar) -> [Int?] {
        guard let interval = calendar.dateInterval(of: .month, for: date),
              let range = calendar.range(of: .day, in: .month, for: date) else { return [] }
        let firstWeekday = calendar.component(.weekday, from: interval.start)
        let leading = (firstWeekday - calendar.firstWeekday + 7) % 7
        return Array(repeating: nil, count: leading) + range.map { Optional($0) }
    }

    var body: some View {
        Button(action: openCalendarApp) {
            Card(padding: 8) {
                TimelineView(.everyMinute) { timeline in
                    let calendar = Calendar(identifier: .gregorian)
                    let today = calendar.component(.day, from: timeline.date)
                    let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)
                    let cells = days(for: timeline.date, calendar: calendar)
                    let symbols = weekdaySymbols(calendar: calendar)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(monthTitle(timeline.date))
                            .font(.system(size: 12, weight: .semibold))
                        LazyVGrid(columns: columns, spacing: 1) {
                            // id 用负数，避免和下面日期格子的 id 重复。
                            ForEach(-7..<0, id: \.self) { offset in
                                Text(symbols[offset + 7]).font(.system(size: 9, weight: .medium)).foregroundStyle(Theme.secondary)
                            }
                            // 同一个网格里两组 ForEach 的 id 不能重复，否则重复的格子会显示成空白。
                            ForEach(cells.indices, id: \.self) { index in
                                let day = cells[index]
                                Text(day.map(String.init) ?? "")
                                    .font(.system(size: 10, weight: day == today ? .bold : .regular))
                                    .monospacedDigit()
                                    .foregroundStyle(day == today ? Color.white : Theme.primary)
                                    .frame(width: 15, height: 13)
                                    .background(RoundedRectangle(cornerRadius: 4).fill(day == today ? Theme.coral : Color.clear))
                            }
                        }
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .help(L("打开日历"))
    }
}
