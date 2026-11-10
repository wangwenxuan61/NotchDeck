import SwiftUI

private var privacyNote: String { L("开启后，NotchDeck 只在本机读取 Claude Code 和 Codex 的用量记录，只统计模型和 token 数，不读取对话内容。") }
private var costNote: String { L("费用按官方 API 价格估算，订阅套餐实际不按 token 计费。") }

/// 各模型的用量明细：输入、缓存读写、输出、合计和估算费用。
struct TokenUsagePage: View {
    @ObservedObject var model: PanelModel
    @ObservedObject private var store = TokenUsageStore.shared
    @State private var range = TokenUsageStore.Range.today

    private static let numberWidth: CGFloat = 82

    var body: some View {
        VStack(spacing: 6) {
            PageHeader(title: L("Token 用量"), model: model) {
                if store.isEnabled { controls }
            }
            Card(padding: 10) { content }
        }
        .onAppear { store.refreshIfNeeded(minInterval: 15) }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Group {
                if store.isScanning {
                    Text(L("正在读取…"))
                } else if let updated = store.lastUpdated {
                    Text(L("更新于 %@", relativeTime(updated)))
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(Theme.secondary)
            Picker("", selection: $range) {
                ForEach(TokenUsageStore.Range.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            Button { store.refresh() } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .disabled(store.isScanning)
            .help(L("刷新"))
        }
    }

    @ViewBuilder private var content: some View {
        let rows = store.rows(for: range)
        if !store.isEnabled {
            VStack(spacing: 10) {
                Text(privacyNote)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
                Button(L("开启")) { store.isEnabled = true }.controlSize(.small)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if rows.isEmpty {
            VStack(spacing: 8) {
                if store.isScanning && store.lastUpdated == nil {
                    ProgressView().controlSize(.small)
                    Text(L("第一次读取需要一点时间，之后只读新增的记录。"))
                } else {
                    Text(L("这段时间没有用量记录"))
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 4) {
                tableRow(model: L("模型"), source: L("来源"), counts: nil, header: true)
                Divider()
                ScrollView(.vertical) {
                    VStack(spacing: 4) {
                        ForEach(rows) { row in tableRow(model: row.model, source: row.source.title, counts: row.counts, priced: row.isPriced) }
                    }
                }
                .scrollIndicators(.never)
                Divider()
                tableRow(model: L("合计"), source: "", counts: rows.reduce(TokenCounts()) { $0 + $1.counts }, bold: true)
                Text(rows.contains { !$0.isPriced } ? costNote + " " + L("没有价格的模型显示为 —。") : costNote)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private func number(_ value: Int?) -> some View {
        Text(value.map(formatTokens) ?? "")
            .monospacedDigit()
            .frame(width: Self.numberWidth, alignment: .trailing)
    }

    private func tableRow(model: String, source: String, counts: TokenCounts?, priced: Bool = true, header: Bool = false, bold: Bool = false) -> some View {
        HStack(spacing: 8) {
            Text(model).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
            Text(source).lineLimit(1).foregroundStyle(Theme.secondary).frame(width: 96, alignment: .leading)
            if header {
                ForEach([L("输入"), L("缓存读取"), L("缓存写入"), L("输出"), L("合计"), L("费用")], id: \.self) { title in
                    Text(title).lineLimit(1).minimumScaleFactor(0.8).frame(width: Self.numberWidth, alignment: .trailing)
                }
            } else {
                number(counts?.input)
                number(counts?.cacheRead)
                number(counts?.cacheWrite)
                number(counts?.output)
                number(counts?.total).fontWeight(.semibold)
                Text(counts.map { priced ? formatDollars($0.cost) : "—" } ?? "")
                    .monospacedDigit()
                    .fontWeight(.semibold)
                    .frame(width: Self.numberWidth, alignment: .trailing)
            }
        }
        .font(.system(size: header ? 11 : 12, weight: bold ? .semibold : .regular))
        .foregroundStyle(header ? Theme.secondary : Theme.primary)
        .help(header || counts == nil ? "" : model)
    }
}

/// 首页卡片：今天的合计和用得最多的两个模型。
struct TokenUsageCard: View {
    @ObservedObject var model: PanelModel
    @ObservedObject private var store = TokenUsageStore.shared

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 4) {
                Button { model.page = .usage } label: {
                    CardHeader(L("Token 用量"), symbol: "chart.bar.xaxis", color: Theme.purple) {
                        Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if store.isEnabled {
                    let rows = store.rows(for: .today)
                    Text(formatTokens(rows.reduce(0) { $0 + $1.counts.total }))
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text(verbatim: "\(L("今天")) · \(formatDollars(rows.reduce(0) { $0 + $1.counts.cost }))")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondary)
                        .help(costNote)
                    Spacer(minLength: 0)
                    ForEach(rows.prefix(2)) { row in
                        HStack(spacing: 6) {
                            Text(row.model).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 4)
                            Text(formatTokens(row.counts.total)).monospacedDigit().foregroundStyle(Theme.secondary)
                        }
                        .font(.system(size: 11))
                    }
                } else {
                    Spacer(minLength: 0)
                    Button(L("开启")) { store.isEnabled = true }
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .help(privacyNote)
                    Spacer(minLength: 0)
                }
            }
        }
    }
}
