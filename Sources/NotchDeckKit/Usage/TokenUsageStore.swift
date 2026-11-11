import Foundation

/// 统计 Claude Code 和 Codex 在本机的 token 用量。默认关闭，开启前不读取任何文件。
/// 只看最近 30 天：更早没改动过的记录文件直接跳过，第一次扫描也快得多。
final class TokenUsageStore: ObservableObject {
    static let shared = TokenUsageStore()
    static let retentionDays = 30
    private static let enabledKey = "tokenUsageEnabled"
    /// 保存格式或价格表变了就把版本号加一，旧的统计会删掉重新读取。
    static let file = "token-usage-v3.json"
    private static let legacyFiles = ["token-usage.json", "token-usage-v2.json"]

    enum Range: CaseIterable {
        case today, week, month

        var days: Int {
            switch self {
            case .today: return 1
            case .week: return 7
            case .month: return 30
            }
        }

        var title: String {
            switch self {
            case .today: return L("今天")
            case .week: return L("%d 天", 7)
            case .month: return L("%d 天", 30)
            }
        }
    }

    struct Row: Identifiable, Equatable {
        var id: String { "\(source.rawValue)|\(model)" }
        let source: UsageSource
        let model: String
        let counts: TokenCounts

        /// 有没有这个模型的价格，没有的话费用显示为 —。
        var isPriced: Bool { TokenPricing.price(for: model) != nil }
    }

    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            isEnabled ? refresh() : clear()
        }
    }
    @Published private(set) var isScanning = false
    @Published private(set) var lastUpdated: Date?
    /// 日期 -> "来源|模型" -> 用量，由各个文件的统计合并而来。
    @Published private(set) var days: [String: [String: TokenCounts]] = [:]

    /// 记录文件所在的目录。检查程序会换成临时目录。
    var roots: [(url: URL, source: UsageSource)] = {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        return [
            (home.appendingPathComponent(".claude/projects"), .claudeCode),
            (home.appendingPathComponent(".codex/sessions"), .codex),
            (home.appendingPathComponent(".codex/archived_sessions"), .codex),
        ]
    }()

    private let queue = DispatchQueue(label: "notchdeck.token-usage", qos: .userInitiated)
    /// 只在 queue 上访问。
    private var files: [String: UsageFileState] = [:]
    /// 已经计入的 Claude Code 请求 ID，由各文件的 ids 合并而来。
    private var seen = Set<String>()
    private var loaded = false

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    /// 面板打开时调用；距离上次刷新不到 minInterval 秒就不重复扫描。
    func refreshIfNeeded(minInterval: TimeInterval = 60) {
        guard isEnabled, !isScanning else { return }
        if let lastUpdated, Date().timeIntervalSince(lastUpdated) < minInterval { return }
        refresh()
    }

    func refresh(completion: (() -> Void)? = nil) {
        guard isEnabled, !isScanning else { completion?(); return }
        isScanning = true
        let roots = roots
        queue.async { [weak self] in
            guard let self else { return }
            if !self.loaded {
                for name in Self.legacyFiles {
                    try? FileManager.default.removeItem(at: Storage.folder.appendingPathComponent(name))
                }
                self.files = Storage.load([String: UsageFileState].self, from: Self.file) ?? [:]
                self.seen = Set(self.files.values.flatMap(\.ids))
                self.loaded = true
            }
            if self.scan(roots) { Storage.save(self.files, to: Self.file) }
            let merged = Self.merge(self.files)
            DispatchQueue.main.async {
                self.isScanning = false
                // 扫描期间被关掉了，就不再显示结果。
                guard self.isEnabled else { completion?(); return }
                if merged != self.days { self.days = merged }
                self.lastUpdated = Date()
                completion?()
            }
        }
    }

    /// 关闭后删掉统计结果，下次开启时重新读取。
    private func clear() {
        days = [:]
        lastUpdated = nil
        queue.async { [weak self] in
            self?.files = [:]
            self?.seen = []
            self?.loaded = true
            try? FileManager.default.removeItem(at: Storage.folder.appendingPathComponent(Self.file))
        }
    }

    private struct Job {
        let path: String
        let url: URL
        let isOld: Bool
        var state: UsageFileState
        var needsRead: Bool
        var entries: [ClaudeEntry] = []
    }

    /// 返回统计有没有变化，没变就不必重写保存的文件。
    /// 先列出要读的文件，再同时读多个文件，最后按原来的顺序去重计入，结果和逐个读完全一样。
    private func scan(_ roots: [(url: URL, source: UsageSource)]) -> Bool {
        var changed = false
        let calendar = Calendar.current
        let cutoffDate = calendar.date(byAdding: .day, value: -(Self.retentionDays - 1), to: calendar.startOfDay(for: Date())) ?? Date()
        let cutoff = UsageParsing.dayKey(for: cutoffDate)
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        var jobs: [Job] = []
        var sizes: [UInt64] = []
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(at: root.url, includingPropertiesForKeys: keys) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
                let path = url.path
                // 30 天内没改过的文件，不会有新的用量。
                let isOld = (values.contentModificationDate ?? Date()) < cutoffDate
                if isOld, files[path] == nil { continue }
                var state = files[path] ?? UsageFileState(source: root.source)
                let size = UInt64(values.fileSize ?? 0)
                // 文件变小说明被重写了，这个文件从头重新统计，它的请求 ID 也要先放回去。
                if size < state.offset {
                    seen.subtract(state.ids)
                    state = UsageFileState(source: root.source)
                    changed = true
                }
                jobs.append(Job(path: path, url: url, isOld: isOld, state: state, needsRead: size > state.offset))
                sizes.append(size - min(size, state.offset))
            }
        }

        // 大文件先读，免得最后只剩一个大文件在单独读。
        let order = jobs.indices.filter { jobs[$0].needsRead }.sorted { sizes[$0] > sizes[$1] }
        jobs.withUnsafeMutableBufferPointer { buffer in
            DispatchQueue.concurrentPerform(iterations: order.count) { index in
                let i = order[index]
                try? UsageParsing.readNewLines(of: buffer[i].url, into: &buffer[i].state, entries: &buffer[i].entries)
            }
        }

        var kept = Set<String>()
        for var job in jobs {
            if job.needsRead {
                UsageParsing.apply(job.entries, to: &job.state, seen: &seen)
                changed = true
            }
            let dayCount = job.state.days.count
            job.state.removeDays(before: cutoff)
            changed = changed || job.state.days.count != dayCount
            // 旧文件的用量都已过期，不必再记着它。没有用量的新文件要保留读取位置，免得每次从头读。
            if job.isOld, job.state.days.isEmpty {
                seen.subtract(job.state.ids)
                if files.removeValue(forKey: job.path) != nil { changed = true }
                continue
            }
            kept.insert(job.path)
            files[job.path] = job.state
        }
        // 文件已删除，或者里面的用量都已超过 30 天。
        for (path, state) in files where !kept.contains(path) {
            seen.subtract(state.ids)
            files[path] = nil
            changed = true
        }
        return changed
    }

    static func merge(_ files: [String: UsageFileState]) -> [String: [String: TokenCounts]] {
        var result: [String: [String: TokenCounts]] = [:]
        for state in files.values {
            for (day, models) in state.days {
                for (model, counts) in models {
                    result[day, default: [:]]["\(state.source.rawValue)|\(model)", default: TokenCounts()] += counts
                }
            }
        }
        return result
    }

    /// 某个时间段内各模型的合计，用量多的排前面。
    func rows(for range: Range, now: Date = Date()) -> [Row] {
        Self.rows(from: days, range: range, now: now)
    }

    static func rows(from days: [String: [String: TokenCounts]], range: Range, now: Date = Date()) -> [Row] {
        let calendar = Calendar.current
        let start = calendar.date(byAdding: .day, value: -(range.days - 1), to: calendar.startOfDay(for: now)) ?? now
        let first = UsageParsing.dayKey(for: start)
        var totals: [String: TokenCounts] = [:]
        for (day, models) in days where day >= first {
            for (key, counts) in models { totals[key, default: TokenCounts()] += counts }
        }
        return totals.compactMap { key, counts -> Row? in
            let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2, let source = UsageSource(rawValue: parts[0]) else { return nil }
            return Row(source: source, model: parts[1], counts: counts)
        }
        .sorted { $0.counts.total != $1.counts.total ? $0.counts.total > $1.counts.total : $0.id < $1.id }
    }
}
