import SwiftUI

/// 每个版本的新功能，写在 App 里，跟着界面语言翻译，不用联网。
/// 发新版本时在 all 最前面加一项，只写用户能感受到的变化，最多四条。
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
            ReleaseNotes(version: "0.1.15", items: [
                Item(symbol: "sparkles", color: Theme.purple,
                     title: L("更新后看看有什么新功能"),
                     detail: L("以后每次更新，打开面板就会先看到这一页；在设置里点版本号可以再看。")),
                Item(symbol: "leaf", color: Theme.teal,
                     title: L("后台更省电"),
                     detail: L("面板收起后不再刷新里面的内容，正在播放的信息也只在打开面板时读取，后台占用降到原来的七分之一左右。")),
            ]),
            ReleaseNotes(version: "0.1.14", items: [
                Item(symbol: "clock.arrow.circlepath", color: Theme.teal,
                     title: L("剪贴板历史重启后还在"),
                     detail: L("图片也会保存。只想留下置顶的内容，可以在剪贴板页关掉“保存历史”。")),
                Item(symbol: "doc.text.magnifyingglass", color: Theme.blue,
                     title: L("查看全文"),
                     detail: L("右键剪贴板里的一条选“查看”：长文字看全文，图片看大图和识别出的文字。")),
                Item(symbol: "text.viewfinder", color: Theme.purple,
                     title: L("按图片里的文字搜索"),
                     detail: L("在剪贴板的搜索框输入截图里的词，就能找到那张图。")),
                Item(symbol: "person.and.background.dotted", color: Theme.orange,
                     title: L("抠出主体"),
                     detail: L("右键图片选“抠出主体”，把人、宠物或物品复制成透明背景的图片。")),
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
