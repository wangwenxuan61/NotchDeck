import Foundation
import SQLite3

/// 统计哪些工具的用量。rawValue 会保存下来，不要改。
enum UsageSource: String, Codable, CaseIterable {
    case claudeCode, codex, gemini, qwen, kimi, zcode, antigravity, opencode, copilot, goose, cline, roo, kilo

    var title: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .gemini: return "Gemini CLI"
        case .qwen: return "Qwen Code"
        case .kimi: return "Kimi"
        case .zcode: return "ZCode"
        case .antigravity: return "Antigravity"
        case .opencode: return "OpenCode"
        case .copilot: return "Copilot CLI"
        case .goose: return "Goose"
        case .cline: return "Cline"
        case .roo: return "Roo Code"
        case .kilo: return "Kilo Code"
        }
    }

    /// 各工具写记录的目录。deep 为 false 的只看目录本身，不往下找：数据库旁边常有成千上万个别的文件。
    static func roots(home: URL) -> [(url: URL, source: UsageSource, deep: Bool)] {
        var paths: [(String, UsageSource, Bool)] = [
            (".claude/projects", .claudeCode, true), (".codex/sessions", .codex, true), (".codex/archived_sessions", .codex, true),
            (".gemini/tmp", .gemini, true), (".qwen/projects", .qwen, true),
            (".kimi/sessions", .kimi, true), (".kimi-code/sessions", .kimi, true),
            ("Library/Application Support/kimi-desktop/daimon-share/daimon/runtime/kimi-code/home/sessions", .kimi, true),
            (".zcode/cli/db", .zcode, false),
            (".gemini/antigravity/conversations", .antigravity, false), (".gemini/antigravity-cli/conversations", .antigravity, false),
            (".local/share/opencode", .opencode, false), (".copilot", .copilot, false),
            (".local/share/goose/sessions", .goose, false), ("Library/Application Support/goose/sessions", .goose, false),
            (".cline/data/sessions", .cline, true), (".local/share/kilo", .kilo, false),
        ]
        // VS Code 一类编辑器里的 Cline、Roo Code、Kilo Code 插件，每个任务一个文件夹。
        for app in ["Code", "Code - Insiders", "Cursor", "Windsurf", "VSCodium"] {
            for (id, source) in [("saoudrizwan.claude-dev", UsageSource.cline), ("rooveterinaryinc.roo-cline", .roo), ("kilocode.kilo-code", .kilo)] {
                paths.append(("Library/Application Support/\(app)/User/globalStorage/\(id)/tasks", source, true))
            }
        }
        return paths.map { (home.appendingPathComponent($0.0), $0.1, $0.2) }
    }

    /// 这个文件是不是用量记录：追加写入的返回 .lines，只读新增的行；整个重写的文件和数据库返回 .whole，有改动就整个重读。
    func mode(of url: URL) -> UsageReadMode? {
        let name = url.lastPathComponent, ext = url.pathExtension
        switch self {
        case .claudeCode, .codex, .qwen: return ext == "jsonl" ? .lines : nil
        case .kimi: return name == "wire.jsonl" ? .lines : nil
        case .zcode: return name == "db.sqlite" ? .whole : nil
        case .antigravity: return ext == "db" ? .whole : nil
        case .gemini:
            // 0.39 起是追加写入的 JSONL，更早是每次整个重写的 JSON。
            guard url.deletingLastPathComponent().pathComponents.contains("chats") else { return nil }
            return ext == "jsonl" ? .lines : ext == "json" ? .whole : nil
        case .opencode: return name.hasPrefix("opencode") && ext == "db" ? .whole : nil
        case .copilot: return name == "session-store.db" ? .whole : nil
        case .goose: return name == "sessions.db" ? .whole : nil
        case .cline: return name == "ui_messages.json" || name.hasSuffix(".messages.json") ? .whole : nil
        case .roo: return name == "ui_messages.json" ? .whole : nil
        case .kilo: return name == "ui_messages.json" || (name.hasPrefix("kilo") && ext == "db") ? .whole : nil
        }
    }
}

enum UsageReadMode { case lines, whole }

extension UsageEntry {
    init(id: String?, day: String, model: String, usage: TokenUsage) {
        var counts = usage.counts
        counts.cost = TokenPricing.cost(of: usage, model: model, day: day) ?? 0
        self.init(id: id, day: day, model: model, counts: counts)
    }

    init(id: String?, seconds: Double, model: String, usage: TokenUsage) {
        self.init(id: id, day: UsageParsing.dayKey(unixSeconds: Int(seconds)), model: model, usage: usage)
    }
}

extension UsageParsing {
    private static let lineNeedles: [UsageSource: [[UInt8]]] = [
        .gemini: ["\"tokens\""], .qwen: ["\"usageMetadata\""],
        .kimi: ["\"StatusUpdate\"", "\"usage.record\"", "\"llm.request\""],
    ].mapValues { $0.map { Array($0.utf8) } }

    /// Gemini CLI、Qwen Code、Kimi 的一行记录。先按字节找关键字，跳过不带用量的行，再解析 JSON。
    static func lineEntry(_ line: UnsafeRawBufferPointer, into state: inout UsageFileState) -> UsageEntry? {
        guard let needles = lineNeedles[state.source], let base = line.baseAddress,
              needles.contains(where: { n in n.withUnsafeBytes { memmem(base, line.count, $0.baseAddress, $0.count) != nil } }),
              let object = try? JSONSerialization.jsonObject(with: Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base),
                                                                       count: line.count, deallocator: .none)) as? [String: Any]
        else { return nil }
        return entry(from: object, into: &state)
    }

    static func entry(from o: [String: Any], into state: inout UsageFileState) -> UsageEntry? {
        switch state.source {
        case .gemini:
            // 同一条消息会写好几遍（拿到用量、工具调用有变化时），按 id 去重。input 含缓存，输出不含思考部分。
            guard o["type"] as? String == "gemini", let t = o["tokens"] as? [String: Any],
                  let day = day(fromTimestamp: o["timestamp"] as? String) else { return nil }
            let cached = int(t["cached"])
            return UsageEntry(id: (o["id"] as? String).map { "gemini:" + $0 }, day: day, model: o["model"] as? String ?? "unknown",
                              usage: TokenUsage(input: max(int(t["input"]) - cached, 0) + int(t["tool"]), cacheRead: cached,
                                                output: int(t["output"]) + int(t["thoughts"])))
        case .qwen:
            // 输入含缓存。OpenAI 兼容接口的输出已含思考部分，Gemini 接口的不含：合计比输入加输出多时才另外加上。
            guard o["type"] as? String == "assistant", let u = o["usageMetadata"] as? [String: Any],
                  let day = day(fromTimestamp: o["timestamp"] as? String) else { return nil }
            let prompt = int(u["promptTokenCount"]), cached = int(u["cachedContentTokenCount"]), output = int(u["candidatesTokenCount"])
            let thoughts = int(u["totalTokenCount"]) > prompt + output ? int(u["thoughtsTokenCount"]) : 0
            return UsageEntry(id: (o["uuid"] as? String).map { "qwen:" + $0 }, day: day, model: o["model"] as? String ?? "unknown",
                              usage: TokenUsage(input: max(prompt - cached, 0), cacheRead: cached, output: output + thoughts))
        case .kimi:
            // 旧版 Kimi CLI：每一步一条 StatusUpdate，模型只在配置文件里。子代理的用量在父会话里也套着记一遍，只算最外层的。
            if let message = o["message"] as? [String: Any] {
                guard message["type"] as? String == "StatusUpdate", let payload = message["payload"] as? [String: Any],
                      let u = payload["token_usage"] as? [String: Any], let seconds = o["timestamp"] as? Double else { return nil }
                return UsageEntry(id: (payload["message_id"] as? String).map { "kimi:" + $0 }, seconds: seconds, model: kimiModel,
                                  usage: TokenUsage(input: int(u["input_other"]), cacheRead: int(u["input_cache_read"]),
                                                    cacheWrite: int(u["input_cache_creation"]), output: int(u["output"])))
            }
            // Kimi Code：用量行里的模型是别名，真正的模型在前面的 llm.request 里。分叉会话会复制记录，按时间和用量去重。
            if o["type"] as? String == "llm.request" { state.model = o["model"] as? String ?? state.model }
            guard o["type"] as? String == "usage.record", let u = o["usage"] as? [String: Any], let ms = o["time"] as? Double else { return nil }
            let usage = TokenUsage(input: int(u["inputOther"]), cacheRead: int(u["inputCacheRead"]),
                                   cacheWrite: int(u["inputCacheCreation"]), output: int(u["output"]))
            return UsageEntry(id: "kimi:\(o["agentId"] ?? "")|\(Int(ms))|\(usage.input)|\(usage.output)", seconds: ms / 1000,
                              model: state.model ?? o["model"] as? String ?? "unknown", usage: usage)
        default:
            return nil
        }
    }

    /// 旧版 Kimi CLI 的模型：~/.kimi/config.toml 里 default_model 指向的 [models.xxx] 的 model。
    static let kimiModel: String = {
        let text = (try? String(contentsOfFile: NSHomeDirectory() + "/.kimi/config.toml", encoding: .utf8)) ?? ""
        var section = "", values: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { section = line.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).replacingOccurrences(of: "\"", with: ""); continue }
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 { values[section + "." + parts[0]] = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
        }
        guard let alias = values[".default_model"] else { return "kimi-for-coding" }
        return values["models.\(alias).model"] ?? alias
    }()

    /// 整个重读的文件：旧版 Gemini CLI 的 JSON 会话、编辑器插件的任务记录和各家的数据库。since 之前的用量不读。
    static func readWhole(_ url: URL, source: UsageSource, since: Date) -> [UsageEntry] {
        var state = UsageFileState(source: source)
        var entries: [UsageEntry] = []
        let ms = Int64(since.timeIntervalSince1970 * 1000)
        switch source {
        case .gemini:
            guard let data = try? Data(contentsOf: url), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let messages = object["messages"] as? [[String: Any]] else { return [] }
            entries = messages.compactMap { entry(from: $0, into: &state) }
        case .zcode:
            // 每次请求一行。input_tokens 含缓存读写。
            SQLite.rows(url, """
                SELECT id, model_id, input_tokens, cache_read_input_tokens, cache_creation_input_tokens, output_tokens,
                       COALESCE(completed_at, started_at) FROM model_usage WHERE COALESCE(completed_at, started_at) >= \(ms)
                """) { r in
                let read = r.int(3), write = r.int(4)
                entries.append(UsageEntry(id: "zcode:" + (r.text(0) ?? ""), seconds: Double(r.int(6)) / 1000, model: r.text(1) ?? "unknown",
                                          usage: TokenUsage(input: max(r.int(2) - read - write, 0), cacheRead: read, cacheWrite: write, output: r.int(5))))
            }
        case .antigravity:
            entries = antigravity(url)
        case .opencode:
            entries = openCode(url, since: ms)
        case .kilo where url.pathExtension == "db":
            entries = openCode(url, since: ms)
        case .copilot:
            // 每次请求一行，时间是 UTC 的 "2026-11-01 12:00:00"。输入含缓存读写。
            SQLite.rows(url, """
                SELECT id, COALESCE(copilot_usage_model, model), CAST(strftime('%s', created_at) AS INTEGER),
                       input_tokens, cache_read_tokens, cache_write_tokens, output_tokens
                FROM assistant_usage_events WHERE created_at >= datetime(\(ms / 1000), 'unixepoch')
                """) { r in entries.append(cachedInput(r, id: "copilot:" + (r.text(0) ?? ""))) }
        case .goose:
            // usage_ledger 每次请求一行（较新的版本才有）。升级时把以前的累计值补记成一行，不算。输入含缓存读写。
            SQLite.rows(url, """
                SELECT l.id, COALESCE(l.model, json_extract(s.model_config_json, '$.model_name')), l.created_timestamp,
                       l.input_tokens, l.cache_read_tokens, l.cache_write_tokens, l.output_tokens
                FROM usage_ledger l LEFT JOIN sessions s ON s.id = l.session_id
                WHERE IFNULL(l.cost_source, '') != 'carried_forward' AND l.created_timestamp >= \(ms / 1000)
                """) { r in entries.append(cachedInput(r, id: "goose:" + (r.text(0) ?? ""))) }
        case .cline, .roo, .kilo:
            entries = clineTask(url, source: source)
        default:
            break
        }
        return entries
    }

    /// 列依次是 id、模型、秒、输入（含缓存读写）、缓存读取、缓存写入、输出。
    private static func cachedInput(_ r: SQLite.Row, id: String) -> UsageEntry {
        let read = r.int(4), write = r.int(5)
        return UsageEntry(id: id, seconds: Double(r.int(2)), model: r.text(1) ?? "unknown",
                          usage: TokenUsage(input: max(r.int(3) - read - write, 0), cacheRead: read, cacheWrite: write, output: r.int(6)))
    }

    /// OpenCode（Kilo CLI 也是它改的）每一步一条消息。2.x 在 session_message 表，1.x 在 message 表；升级时旧消息按原 id 复制过去，
    /// 两张表都读，按 id 去重。输入不含缓存，推理单独记，算进输出。
    private static func openCode(_ url: URL, since ms: Int64) -> [UsageEntry] {
        let tokens = """
            json_extract(data, '$.tokens.input'), json_extract(data, '$.tokens.cache.read'), json_extract(data, '$.tokens.cache.write'),
            IFNULL(json_extract(data, '$.tokens.output'), 0) + IFNULL(json_extract(data, '$.tokens.reasoning'), 0), json_extract(data, '$.time.created')
            """
        var entries: [UsageEntry] = []
        for sql in ["SELECT id, json_extract(data, '$.model.id'), \(tokens) FROM session_message WHERE type = 'assistant' AND time_created >= \(ms)",
                    "SELECT id, json_extract(data, '$.modelID'), \(tokens) FROM message WHERE json_extract(data, '$.role') = 'assistant' AND time_created >= \(ms)"] {
            SQLite.rows(url, sql) { r in
                entries.append(UsageEntry(id: "opencode:" + (r.text(0) ?? ""), seconds: Double(r.int(6)) / 1000, model: r.text(1) ?? "unknown",
                                          usage: TokenUsage(input: r.int(2), cacheRead: r.int(3), cacheWrite: r.int(4), output: r.int(5))))
            }
        }
        return entries
    }

    /// Cline、Roo Code、Kilo Code 插件的 ui_messages.json：每次请求一条 api_req_started，用量在 text 里的 JSON。
    /// Cline 的 tokensIn 不含缓存，Roo 和 Kilo 的含（2025 年 11 月起）。旧版没在每条里记模型，就用对话记录里最后一个 <model> 标签。
    /// Cline 命令行版是 <id>.messages.json，每轮最后一条回复带 metrics，输入含缓存。
    private static func clineTask(_ url: URL, source: UsageSource) -> [UsageEntry] {
        guard let data = try? Data(contentsOf: url), let object = try? JSONSerialization.jsonObject(with: data) else { return [] }
        if let messages = (object as? [String: Any])?["messages"] as? [[String: Any]] {
            return messages.compactMap { m in
                guard m["role"] as? String == "assistant", let u = m["metrics"] as? [String: Any], let ms = m["ts"] as? Double else { return nil }
                let read = int(u["cacheReadTokens"]), write = int(u["cacheWriteTokens"])
                return UsageEntry(id: (m["id"] as? String).map { "cline:" + $0 }, seconds: ms / 1000,
                                  model: (m["modelInfo"] as? [String: Any])?["id"] as? String ?? "unknown",
                                  usage: TokenUsage(input: max(int(u["inputTokens"]) - read - write, 0), cacheRead: read, cacheWrite: write, output: int(u["outputTokens"])))
            }
        }
        var fallback: String?
        func taskModel() -> String {
            if fallback == nil {
                let history = (try? String(contentsOf: url.deletingLastPathComponent().appendingPathComponent("api_conversation_history.json"), encoding: .utf8)) ?? ""
                let start = history.range(of: "<model>", options: .backwards)
                let end = start.flatMap { history.range(of: "</model>", range: $0.upperBound..<history.endIndex) }
                fallback = start.flatMap { start in end.map { String(history[start.upperBound..<$0.lowerBound]) } } ?? "unknown"
            }
            return fallback ?? "unknown"
        }
        let task = url.deletingLastPathComponent().lastPathComponent
        return (object as? [[String: Any]] ?? []).compactMap { m in
            guard m["say"] as? String == "api_req_started", let ms = m["ts"] as? Double, let text = m["text"] as? String,
                  let u = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], u["tokensIn"] != nil else { return nil }
            let read = int(u["cacheReads"]), write = int(u["cacheWrites"])
            let input = int(u["tokensIn"]) - (source == .cline ? 0 : read + write)
            return UsageEntry(id: "\(source.rawValue):\(task):\(Int(ms))", seconds: ms / 1000,
                              model: (m["modelInfo"] as? [String: Any])?["modelId"] as? String ?? taskModel(),
                              usage: TokenUsage(input: max(input, 0), cacheRead: read, cacheWrite: write, output: int(u["tokensOut"])))
        }
    }

    /// Antigravity 每次生成在 gen_metadata 里记一行 protobuf，字段号来自 agy 程序里的定义（codeburn、tokscale 都这样读）：
    /// 1.4 是用量（2 输入、3 输出含思考、4 缓存写入、5 缓存读取、11 响应 ID），1.19 是模型 ID，1.9.4 是时间。
    /// 新版本没有时间，就用同一个响应 ID 的步骤时间，再没有就用对话的创建时间。
    private static func antigravity(_ url: URL) -> [UsageEntry] {
        var stepTimes: [String: Int] = [:]
        SQLite.rows(url, "SELECT metadata FROM steps") { r in
            guard let step = Protobuf(r.blob(0)), let id = step.message(9)?.string(11), let time = step.message(1)?.int(1) else { return }
            stepTimes[id] = stepTimes[id] ?? time
        }
        var created: Int?
        SQLite.rows(url, "SELECT data FROM trajectory_metadata_blob") { r in created = created ?? Protobuf(r.blob(0))?.message(2)?.int(1) }
        let fallback = created ?? Int((try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? 0)
        var entries: [UsageEntry] = []
        SQLite.rows(url, "SELECT data FROM gen_metadata") { r in
            guard let root = Protobuf(r.blob(0)), let gen = root.message(1), let u = gen.message(4), let id = u.string(11) else { return }
            let usage = TokenUsage(input: u.int(2) ?? 0, cacheRead: u.int(5) ?? 0, cacheWrite: u.int(4) ?? 0, output: u.int(3) ?? 0)
            let seconds = gen.message(9)?.message(4)?.int(1) ?? stepTimes[id] ?? fallback
            let model = gen.string(19) ?? root.message(3)?.string(28) ?? gen.string(21) ?? "unknown"
            entries.append(UsageEntry(id: "agy:\(url.lastPathComponent):\(id)", seconds: Double(seconds), model: model, usage: usage))
        }
        return entries
    }
}

/// 只读打开 SQLite 数据库，逐行回调。打不开、表不存在或者被锁住时什么都不做。
enum SQLite {
    struct Row {
        let statement: OpaquePointer
        func int(_ column: Int32) -> Int { Int(sqlite3_column_int64(statement, column)) }
        func text(_ column: Int32) -> String? { sqlite3_column_text(statement, column).map { String(cString: $0) } }
        func blob(_ column: Int32) -> [UInt8] {
            guard let bytes = sqlite3_column_blob(statement, column) else { return [] }
            return Array(UnsafeRawBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(statement, column))))
        }
    }

    static func rows(_ url: URL, _ sql: String, _ body: (Row) -> Void) {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else { return }
        sqlite3_busy_timeout(db, 500)
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return }
        while sqlite3_step(statement) == SQLITE_ROW { body(Row(statement: statement)) }
    }
}

/// 不需要 .proto 定义的 protobuf 读取：只记下这一层每个字段号的第一个值，嵌套的消息用到时再解析。
struct Protobuf {
    private var varints: [Int: Int] = [:]
    private var bytes: [Int: ArraySlice<UInt8>] = [:]

    init?(_ data: some Collection<UInt8>) {
        let data = Array(data)
        var i = 0
        func varint() -> Int? {
            var value = 0, shift = 0
            while i < data.count, shift < 64 {
                let byte = data[i]
                i += 1
                value |= Int(byte & 0x7F) << shift
                if byte < 0x80 { return value }
                shift += 7
            }
            return nil
        }
        while i < data.count {
            guard let key = varint(), key >> 3 > 0 else { return nil }
            let field = key >> 3
            switch key & 7 {
            case 0: guard let value = varint() else { return nil }; varints[field] = varints[field] ?? value
            case 1: i += 8
            case 5: i += 4
            case 2:
                guard let length = varint(), length >= 0, length <= data.count - i else { return nil }
                bytes[field] = bytes[field] ?? data[i..<i + length]
                i += length
            default: return nil
            }
        }
        guard i == data.count else { return nil }
    }

    func int(_ field: Int) -> Int? { varints[field] }
    func message(_ field: Int) -> Protobuf? { bytes[field].flatMap { Protobuf($0) } }
    func string(_ field: Int) -> String? { bytes[field].flatMap { String(bytes: $0, encoding: .utf8) }.flatMap { $0.isEmpty ? nil : $0 } }
}
