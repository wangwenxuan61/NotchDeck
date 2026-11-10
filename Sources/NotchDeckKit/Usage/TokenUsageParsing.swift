import Foundation

/// 一组 token 数。输入只算没命中缓存的部分，缓存读取和写入单独列出，输出包含推理部分，所以四项相加就是合计。
struct TokenCounts: Codable, Equatable {
    var input = 0
    var cacheRead = 0
    var cacheWrite = 0
    var output = 0
    /// 按 API 价格估算的费用，美元。没有价格的模型为 0。
    var cost = 0.0

    var total: Int { input + cacheRead + cacheWrite + output }

    static func + (lhs: TokenCounts, rhs: TokenCounts) -> TokenCounts {
        TokenCounts(input: lhs.input + rhs.input, cacheRead: lhs.cacheRead + rhs.cacheRead,
                    cacheWrite: lhs.cacheWrite + rhs.cacheWrite, output: lhs.output + rhs.output, cost: lhs.cost + rhs.cost)
    }

    static func += (lhs: inout TokenCounts, rhs: TokenCounts) { lhs = lhs + rhs }
}

enum UsageSource: String, Codable, CaseIterable {
    case claudeCode, codex

    var title: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        }
    }
}

/// Codex 记录里的原始累计值。
struct CodexTotals: Codable, Equatable {
    var input = 0
    var cached = 0
    var cacheWrite = 0
    var output = 0

    init(input: Int = 0, cached: Int = 0, cacheWrite: Int = 0, output: Int = 0) {
        self.input = input
        self.cached = cached
        self.cacheWrite = cacheWrite
        self.output = output
    }

    init(_ dictionary: [String: Any]) {
        input = UsageParsing.int(dictionary["input_tokens"])
        cached = UsageParsing.int(dictionary["cached_input_tokens"])
        cacheWrite = UsageParsing.int(dictionary["cache_write_input_tokens"])
        output = UsageParsing.int(dictionary["output_tokens"])
    }

    func isAtLeast(_ other: CodexTotals) -> Bool {
        input >= other.input && cached >= other.cached && cacheWrite >= other.cacheWrite && output >= other.output
    }

    static func - (lhs: CodexTotals, rhs: CodexTotals) -> CodexTotals {
        CodexTotals(input: lhs.input - rhs.input, cached: lhs.cached - rhs.cached,
                    cacheWrite: lhs.cacheWrite - rhs.cacheWrite, output: lhs.output - rhs.output)
    }

    /// 按 OpenAI 的惯例，输入 token 已经包含缓存读写的部分，单独列出时要从输入里扣掉，否则会重复计算。
    var usage: TokenUsage {
        TokenUsage(input: max(input - cached - cacheWrite, 0), cacheRead: cached, cacheWrite: cacheWrite, output: output)
    }
}

/// 一个记录文件读到哪里、各天各模型用了多少。按文件分开保存，某个文件需要重读时只替换它自己的部分，不会重复累加。
struct UsageFileState: Codable {
    var source: UsageSource
    var offset: UInt64 = 0
    /// 日期 -> 模型 -> 用量。
    var days: [String: [String: TokenCounts]] = [:]
    /// 这个文件里计入的 Claude Code 请求 ID。同一次请求会在文件里记好几遍，恢复或分叉会话时还会复制到别的文件，
    /// 所以要跨文件去重；文件被删除或重写时，靠这份列表把它的 ID 从全局去重集合里移除。
    var ids: [String] = []
    /// Codex 的当前模型和上一次的累计值。
    var codexModel: String?
    var codexTotal: CodexTotals?

    init(source: UsageSource) { self.source = source }

    mutating func add(_ counts: TokenCounts, day: String, model: String) {
        guard counts.total > 0 else { return }
        days[day, default: [:]][model, default: TokenCounts()] += counts
    }

    mutating func removeDays(before cutoff: String) {
        days = days.filter { $0.key >= cutoff }
    }
}

/// Claude Code 的一条用量，跨文件去重后才计入。
struct ClaudeEntry {
    var id: String?
    var day: String
    var model: String
    var counts: TokenCounts
}

/// 解析 Claude Code 和 Codex 写在本机的记录。只取模型、时间和 token 数，不读对话内容。
enum UsageParsing {
    private static let tokenCountNeedle = Array("\"token_count\"".utf8)
    private static let turnContextNeedle = Array("\"turn_context\"".utf8)

    static func int(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? 0 }

    private static let isoWithFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let iso = ISO8601DateFormatter()
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// 按本地时区的日期，比如 2026-11-10。
    static func dayKey(for date: Date) -> String { dayFormatter.string(from: date) }

    static func day(fromTimestamp text: String?) -> String? {
        guard let text else { return nil }
        if let day = utcDay(text) { return day }
        guard let date = isoWithFraction.date(from: text) ?? iso.date(from: text) else { return nil }
        return dayKey(for: date)
    }

    /// 两边的时间戳都是 UTC，比如 2026-11-10T03:12:45.123Z。直接按数字换算成本地日期，不经过日期格式化器：
    /// 多个线程同时读文件时，共用的格式化器会互相等锁，第一次读取的时间会多出两倍多。其他格式交给格式化器。
    private static func utcDay(_ text: String) -> String? {
        var text = text
        return text.withUTF8 { b -> String? in
            guard b.count >= 20, b[b.count - 1] == UInt8(ascii: "Z"), b[4] == UInt8(ascii: "-"), b[7] == UInt8(ascii: "-"),
                  b[10] == UInt8(ascii: "T"), b[13] == UInt8(ascii: ":"), b[16] == UInt8(ascii: ":") else { return nil }
            var valid = true
            func number(_ start: Int, _ length: Int) -> Int {
                var value = 0
                for index in start..<start + length {
                    let digit = Int(b[index]) - 48
                    if digit < 0 || digit > 9 { valid = false }
                    value = value * 10 + digit
                }
                return value
            }
            let year = number(0, 4), month = number(5, 2), day = number(8, 2)
            let seconds = daysFromCivil(year, month, day) * 86_400 + number(11, 2) * 3_600 + number(14, 2) * 60 + number(17, 2)
            guard valid, (1...12).contains(month), (1...31).contains(day) else { return nil }
            let local = seconds + TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: Double(seconds)))
            let (y, m, d) = civilFromDays(local >= 0 ? local / 86_400 : (local - 86_399) / 86_400)
            return String(format: "%04d-%02d-%02d", y, m, d)
        }
    }

    /// 公历日期和 1970-01-01 起的天数互换（Howard Hinnant 的算法）。
    private static func daysFromCivil(_ year: Int, _ month: Int, _ day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    private static func civilFromDays(_ days: Int) -> (Int, Int, Int) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let mp = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        return (month <= 2 ? yearOfEra + era * 400 + 1 : yearOfEra + era * 400, month, day)
    }

    /// 一行记录。Claude Code 的用量先放进 entries，由 apply 统一去重；Codex 直接计入。
    static func consume(_ line: Data, into state: inout UsageFileState, entries: inout [ClaudeEntry]) {
        switch state.source {
        case .claudeCode:
            if let entry = line.withUnsafeBytes(claudeEntry) { entries.append(entry) }
        case .codex: consumeCodex(line, into: &state)
        }
    }

    /// 读一行并立即去重计入，检查程序用。seen 是所有文件共用的请求 ID 集合。
    static func consume(_ line: Data, into state: inout UsageFileState, seen: inout Set<String>) {
        var entries: [ClaudeEntry] = []
        consume(line, into: &state, entries: &entries)
        apply(entries, to: &state, seen: &seen)
    }

    /// 按顺序计入 Claude Code 的用量，已经在任何文件里出现过的请求 ID 跳过。
    static func apply(_ entries: [ClaudeEntry], to state: inout UsageFileState, seen: inout Set<String>) {
        for entry in entries {
            if let id = entry.id {
                guard seen.insert(id).inserted else { continue }
                state.ids.append(id)
            }
            state.add(entry.counts, day: entry.day, model: entry.model)
        }
    }

    /// 用 JSONScanner 只取时间、请求 ID、模型和用量，跳过对话内容；只有用量这一小段交给 JSONSerialization。
    private static func claudeEntry(_ line: UnsafeRawBufferPointer) -> ClaudeEntry? {
        var scanner = JSONScanner(line)
        guard scanner.enterObject() else { return nil }
        var timestamp: String?
        var id: String?
        var model: String?
        var usageRange: Range<Int>?
        while let key = scanner.nextKey() {
            if scanner.key(key, is: "timestamp") {
                timestamp = scanner.stringValue()
            } else if scanner.key(key, is: "message"), scanner.atObject() {
                _ = scanner.enterObject()
                while let inner = scanner.nextKey() {
                    if scanner.key(inner, is: "id") {
                        id = scanner.stringValue()
                    } else if scanner.key(inner, is: "model") {
                        model = scanner.stringValue()
                    } else if scanner.key(inner, is: "usage"), scanner.atObject() {
                        usageRange = scanner.skipValue()
                    } else {
                        scanner.skipValue()
                    }
                }
            } else {
                scanner.skipValue()
            }
            if scanner.failed { return nil }
        }
        guard !scanner.failed, let usageRange, let model, let start = line.baseAddress,
              let day = day(fromTimestamp: timestamp) else { return nil }
        let usageData = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: start + usageRange.lowerBound),
                             count: usageRange.count, deallocator: .none)
        guard let usage = try? JSONSerialization.jsonObject(with: usageData) as? [String: Any] else { return nil }
        // 缓存写入分 5 分钟和 1 小时两种，价格不同；旧记录没有细分时都按 5 分钟算。
        let written = int(usage["cache_creation_input_tokens"])
        var writeLong = 0
        if let creation = usage["cache_creation"] as? [String: Any] {
            writeLong = min(int(creation["ephemeral_1h_input_tokens"]), written)
        }
        let tokens = TokenUsage(
            input: int(usage["input_tokens"]),
            cacheRead: int(usage["cache_read_input_tokens"]),
            cacheWrite: written - writeLong,
            cacheWriteLong: writeLong,
            output: int(usage["output_tokens"]),
            fast: usage["speed"] as? String == "fast",
            regionMultiplier: usage["inference_geo"] as? String == "us" ? 1.1 : 1
        )
        var counts = tokens.counts
        counts.cost = TokenPricing.cost(of: tokens, model: model) ?? 0
        return ClaudeEntry(id: id, day: day, model: model, counts: counts)
    }

    /// Codex 每次请求后记一条累计值。正常情况按累计的增量算，能补上中间没单独记录的请求；
    /// 累计值变小（会话重置）或是文件里的第一条时，用这一条的单次用量，避免把续接会话之前的用量再算一遍。
    private static func consumeCodex(_ line: Data, into state: inout UsageFileState) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let payload = object["payload"] as? [String: Any] else { return }
        if object["type"] as? String == "turn_context" {
            if let model = payload["model"] as? String { state.codexModel = model }
            return
        }
        guard payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any],
              let totalDictionary = info["total_token_usage"] as? [String: Any] else { return }
        let total = CodexTotals(totalDictionary)
        guard total != state.codexTotal else { return }
        let last = (info["last_token_usage"] as? [String: Any]).map(CodexTotals.init)
        let used: CodexTotals
        if let previous = state.codexTotal, total.isAtLeast(previous) {
            used = total - previous
        } else {
            used = last ?? total
        }
        state.codexTotal = total
        guard let day = day(fromTimestamp: object["timestamp"] as? String) else { return }
        let model = state.codexModel ?? "unknown"
        var counts = used.usage.counts
        counts.cost = TokenPricing.cost(of: used.usage, model: model) ?? 0
        state.add(counts, day: day, model: model)
    }

    /// Codex 的记录先用字节查找跳过不相关的行，只有可能带用量的行才解析 JSON。
    private static func isCodexUsage(_ bytes: UnsafeRawBufferPointer) -> Bool {
        func contains(_ needle: [UInt8]) -> Bool {
            needle.withUnsafeBytes { memmem(bytes.baseAddress, bytes.count, $0.baseAddress, $0.count) != nil }
        }
        return contains(tokenCountNeedle) || contains(turnContextNeedle)
    }

    /// 从 offset 开始读文件里新增的完整行。最后一行如果还没写完就留到下次，offset 停在最后一个换行符之后。
    /// Claude Code 的用量放进 entries，之后由 apply 去重计入，这样多个文件可以同时读。
    static func readNewLines(of url: URL, into state: inout UsageFileState, entries: inout [ClaudeEntry]) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: state.offset)
        var pending = Data()
        var reachedEnd = false
        while !reachedEnd {
            // 读文件和解析 JSON 都会产生临时对象，后台线程不会自动释放。读取这一步也要放进来，
            // 否则读过的每一块数据都会留到整个扫描结束，读几 GB 的记录时内存会涨到 GB 级。
            try autoreleasepool {
                guard let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty else {
                    reachedEnd = true
                    return
                }
                pending.append(chunk)
                let consumed = pending.withUnsafeBytes { buffer -> Int in
                    guard let base = buffer.baseAddress else { return 0 }
                    var start = 0
                    while start < buffer.count, let newline = memchr(base + start, 0x0A, buffer.count - start) {
                        let end = base.distance(to: UnsafeRawPointer(newline))
                        let line = UnsafeRawBufferPointer(start: base + start, count: end - start)
                        guard !line.isEmpty else {
                            start = end + 1
                            continue
                        }
                        switch state.source {
                        case .claudeCode:
                            // 扫描器按结构跳过对话内容，比先在整行里找 "usage" 还快，所以每一行都直接扫。
                            if let entry = claudeEntry(line) { entries.append(entry) }
                        case .codex:
                            // 不复制这一行，直接在读到的数据上解析。
                            if isCodexUsage(line) {
                                consumeCodex(Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base + start), count: line.count, deallocator: .none), into: &state)
                            }
                        }
                        start = end + 1
                    }
                    return start
                }
                state.offset += UInt64(consumed)
                pending = consumed == pending.count ? Data() : pending.subdata(in: consumed..<pending.count)
            }
        }
    }

    /// 读完立即去重计入，检查程序用。
    static func readNewLines(of url: URL, into state: inout UsageFileState, seen: inout Set<String>) throws {
        var entries: [ClaudeEntry] = []
        defer { apply(entries, to: &state, seen: &seen) }
        try readNewLines(of: url, into: &state, entries: &entries)
    }
}
