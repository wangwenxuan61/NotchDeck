import SwiftUI

/// 每个版本的新功能，写在 App 里，跟着界面语言翻译，不用联网。
/// 发新版本时把 all 里的换成新版本的，只写用户能感受到的变化，最多四条。
/// App 只显示当前版本（没写的话是之前最近一版）的新功能，更早的不会再显示，所以只留最新一份。
struct ReleaseNotes {
    struct Item {
        let symbol: String
        let color: Color
        let title: String
        let detail: String
    }

    let version: String
    let items: [Item]

    /// 文字在用到时才取，这样换语言后显示的也是新语言。
    static var all: [ReleaseNotes] {
        [
            ReleaseNotes(version: "0.1.18", items: [
                Item(symbol: "briefcase.fill", color: Theme.purple,
                     title: L("装忙多了六个场景"),
                     detail: L("监控大屏、编译和测试、服务器运维、做表格、MATLAB 仿真和读文献。")),
                Item(symbol: "display.2", color: Theme.blue,
                     title: L("每块屏幕分别选场景"),
                     detail: L("接了外接显示器时，每块屏幕可以选不同的场景；竖屏会改成上下排。")),
                Item(symbol: "text.viewfinder", color: Theme.teal,
                     title: L("框选识字"),
                     detail: L("在快捷开关页点“识字”或按 ⌃⌥T，框选屏幕上的文字直接复制。")),
                Item(symbol: "eyedropper", color: Theme.orange,
                     title: L("取色"),
                     detail: L("点“取色”或按 ⌃⌥C，再点屏幕上任意位置，复制它的色值。")),
            ]),
        ]
    }

    static func notes(for version: String) -> ReleaseNotes? {
        all.first { $0.version == version }
    }

    /// 设置页点版本号时显示的：当前版本的，没有就显示更早的里最新的一份。
    static func latest(upTo version: String) -> ReleaseNotes? {
        all.filter { $0.version.compare(version, options: .numeric) != .orderedDescending }
            .max { $0.version.compare($1.version, options: .numeric) == .orderedAscending }
    }
}

struct WhatsNewPage: View {
    @ObservedObject var model: PanelModel
    @ObservedObject private var updates = UpdateChecker.shared

    private var notes: ReleaseNotes? { ReleaseNotes.latest(upTo: updates.currentVersion) }

    var body: some View {
        VStack(spacing: 6) {
            PageHeader(title: L("%@ 新功能", notes?.version ?? updates.currentVersion), model: model, backTo: model.whatsNewReturn) {
                PillButton(title: L("知道了"), prominent: true) { model.page = model.whatsNewReturn }
                    .keyboardShortcut(.defaultAction)
            }
            Card(padding: 10) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(Array((notes?.items ?? []).enumerated()), id: \.offset) { _, item in
                        WhatsNewRow(item: item)
                    }
                }
            }
        }
    }
}

/// 只是说明，不能点：看完新功能就回到原来的地方，不在这里跳去别的页面。
private struct WhatsNewRow: View {
    let item: ReleaseNotes.Item

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(item.color)
                .frame(width: 34, height: 34)
                .background(Circle().fill(item.color.opacity(0.14)))
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(item.detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .topLeading)
    }
}
