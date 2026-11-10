import AppKit
@testable import NotchDeckKit

// 逻辑检查：不依赖 XCTest，只装命令行工具也能运行。用法：swift run NotchDeckChecks
// 检查只覆盖不需要界面和系统授权的逻辑；界面和权限相关的行为仍需要手动验证。

// 用临时目录代替真实的 Application Support，检查不会读写用户的数据。
let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent("NotchDeckChecks-\(getpid())")
try? FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
setenv("CFFIXED_USER_HOME", sandbox.path, 1)
setenv("HOME", sandbox.path, 1)

var passed = 0
var failed: [String] = []

func check(_ name: String, _ condition: @autoclosure () -> Bool, line: Int = #line) {
    if condition() {
        passed += 1
    } else {
        failed.append("main.swift:\(line): \(name)")
        print("  FAIL \(name)")
    }
}

func section(_ title: String, _ body: () -> Void) {
    print(title)
    body()
}

/// 让主线程跑一会儿，定时器和异步回调才会执行。
func pump(_ seconds: TimeInterval) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

guard Storage.folder.path.hasPrefix(sandbox.path) else {
    print("Storage 没有指向临时目录，为了不碰真实数据，停止检查：\(Storage.folder.path)")
    exit(2)
}

section("格式化") {
    check("分钟", formatDuration(minutes: 15) == L("%d 分钟", 15))
    check("整小时", formatDuration(minutes: 60) == L("%d 小时", 1))
    check("小时加分钟", formatDuration(minutes: 75) == L("%d 小时 %d 分钟", 1, 15))
    check("短格式", formatCompactDuration(minutes: 42) == "42m" && formatCompactDuration(minutes: 240) == "4h" && formatCompactDuration(minutes: 75) == "1h15m")
    check("网速", formatSpeed(1_234_567) == "1.2 MB/s" && formatSpeed(44_000) == "44 KB/s")
    check("菜单栏网速", formatCompactSpeed(1_234_567) == "1.2M" && formatCompactSpeed(44_000) == "44K")
    check("温度四舍五入", formatTemperature(61.6) == "62°C" && formatTemperature(nil) == nil)
    let now = Date()
    check("刚刚", relativeTime(now.addingTimeInterval(-30)) == L("刚刚"))
    check("分钟前", relativeTime(now.addingTimeInterval(-125)) == L("%d 分钟前", 2))
    check("小时前", relativeTime(now.addingTimeInterval(-7_300)) == L("%d 小时前", 2))
    check("天前", relativeTime(now.addingTimeInterval(-2 * 86_400 - 10)) == L("%d 天前", 2))
}

section("12 / 24 小时制判断") {
    check("中文 24 小时", !isTwelveHourPattern("H時"))
    check("中文 12 小时用时段字段 B", isTwelveHourPattern("Bh時"))
    check("英文 12 小时", isTwelveHourPattern("h:mm a"))
    check("K 也是 12 小时", isTwelveHourPattern("K:mm a"))
    check("法语引号里的 h 不算", !isTwelveHourPattern("HH 'h' mm"))
}

section("版本比较") {
    check("去掉 v 前缀", UpdateChecker.newerVersion(tag: "v0.1.6", than: "0.1.5") == "0.1.6")
    check("按数字比较", UpdateChecker.newerVersion(tag: "v0.1.10", than: "0.1.9") == "0.1.10")
    check("同一版本不算新", UpdateChecker.newerVersion(tag: "v0.1.5", than: "0.1.5") == nil)
    check("旧版本不算新", UpdateChecker.newerVersion(tag: "0.2.0", than: "0.10.0") == nil)
}

section("会议链接") {
    let link = { (text: String?) in AgendaStore.joinURL(in: [text])?.absoluteString }
    check("Zoom，去掉结尾标点", link("Join: https://acme.zoom.us/j/123?pwd=x.") == "https://acme.zoom.us/j/123?pwd=x")
    check("Google Meet", link("see https://meet.google.com/abc-defg-hij now") == "https://meet.google.com/abc-defg-hij")
    check("腾讯会议", link("https://meeting.tencent.com/dm/abc") == "https://meeting.tencent.com/dm/abc")
    check("飞书", link("https://vc.feishu.cn/j/123456") == "https://vc.feishu.cn/j/123456")
    check("普通网址不算", link("https://example.com/doc") == nil)
    check("仿冒域名不算", link("https://zoom.us.evil.com/j/1") == nil && link("https://evil.com/zoom.us/j/1") == nil)
    check("依次查找各个字段", AgendaStore.joinURL(in: [nil, "Room 3", "https://zoom.us/j/9"])?.absoluteString == "https://zoom.us/j/9")
}

section("今日日程") {
    let now = Date()
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: now)
    func at(day: Int, hour: Int) -> Date {
        calendar.date(byAdding: .hour, value: hour, to: calendar.date(byAdding: .day, value: day, to: today)!)!
    }
    func item(_ title: String, _ start: Date, _ end: Date, allDay: Bool = false) -> AgendaStore.Item {
        AgendaStore.Item(id: title, title: title, start: start, end: end, isAllDay: allDay, color: NSColor.systemBlue.cgColor, joinURL: nil)
    }
    let list = AgendaStore.upcoming([
        item("allday", now.addingTimeInterval(-100), now.addingTimeInterval(9_000), allDay: true),
        item("late", now.addingTimeInterval(7_200), now.addingTimeInterval(7_300)),
        item("past", now.addingTimeInterval(-7_200), now.addingTimeInterval(-3_600)),
        item("soon", now.addingTimeInterval(600), now.addingTimeInterval(900)),
        item("now", now.addingTimeInterval(-60), now.addingTimeInterval(300)),
    ], at: now)
    check("去掉已结束的，有时间的排在全天前面", list.map(\.title) == ["now", "soon", "late", "allday"])
    let meeting = item("x", now.addingTimeInterval(1_800), now.addingTimeInterval(3_600))
    check("进行中", AgendaStore.countdown(to: item("x", now.addingTimeInterval(-60), now.addingTimeInterval(60)), at: now) == L("进行中"))
    check("分钟后", AgendaStore.countdown(to: meeting, at: meeting.start.addingTimeInterval(-1_800)) == L("%d 分钟后", 30))
    check("不足一分钟按一分钟算", AgendaStore.countdown(to: meeting, at: meeting.start.addingTimeInterval(-1_790)) == L("%d 分钟后", 30))
    check("小时后", AgendaStore.countdown(to: meeting, at: meeting.start.addingTimeInterval(-7_300)) == L("%d 小时后", 2))
    check("全天日程没有倒计时", AgendaStore.countdown(to: item("x", now, now.addingTimeInterval(60), allDay: true), at: now) == nil)
    check("昨天开始今天结束显示结束时间", AgendaStore.timeLabel(item("x", at(day: -1, hour: 22), at(day: 0, hour: 9)), at: now) == L("至 %@", formatClockTime(at(day: 0, hour: 9))))
    check("占满今天显示全天", AgendaStore.timeLabel(item("x", at(day: -1, hour: 22), at(day: 1, hour: 9)), at: now) == L("全天"))
    check("今天开始显示开始时间", AgendaStore.timeLabel(item("x", at(day: 0, hour: 14), at(day: 0, hour: 15)), at: now) == formatClockTime(at(day: 0, hour: 14)))
}

section("读数平滑") {
    var smoother = Smoother()
    let start = Date()
    check("第一个值原样返回", smoother.add(10, at: start) == 10)
    check("之后每次靠近 35%", abs(smoother.add(20, at: start.addingTimeInterval(2)) - 13.5) < 1e-9)
    check("隔太久就重新开始", smoother.add(50, at: start.addingTimeInterval(40)) == 50)
}

section("剪贴板去重") {
    typealias Content = ClipboardStore.Content
    let png = Data([1, 2, 3])
    check("相同文字", ClipboardStore.isSameContent(.text("a"), .text("a")))
    check("不同文字", !ClipboardStore.isSameContent(.text("a"), .text("b")))
    check("相同图片", ClipboardStore.isSameContent(.image(NSImage(), png, .png), .image(NSImage(), png, .png)))
    check("同一路径的两种写法", ClipboardStore.isSameContent(.files([URL(fileURLWithPath: "/Applications")]), .files([URL(fileURLWithPath: "/Applications/")])))
    check("不同类型", !ClipboardStore.isSameContent(.text("/Applications"), .files([URL(fileURLWithPath: "/Applications")])))
}

section("图片识字") {
    let size = NSSize(width: 900, height: 160)
    let image = NSImage(size: size)
    image.lockFocus()
    NSColor.white.setFill()
    NSRect(origin: .zero, size: size).fill()
    ("NotchDeck OCR 2026" as NSString).draw(at: NSPoint(x: 30, y: 50), withAttributes: [.font: NSFont.systemFont(ofSize: 56), .foregroundColor: NSColor.black])
    image.unlockFocus()
    let text = image.cgImage(forProposedRect: nil, context: nil, hints: nil).flatMap(ClipboardStore.recognizeText) ?? ""
    check("识别出文字和数字", text.contains("NotchDeck") && text.contains("2026"))
}

section("计时") {
    let clock = CountdownClock()
    var changes: [Int] = []
    var finished = false
    clock.onChange = { changes.append($0) }
    clock.onFinish = { finished = true }
    clock.start(seconds: 2)
    pump(2.7)
    check("每秒报告一次，到点结束", changes == [1] && finished)
    check("时间格式", FocusTimer.format(65) == "01:05" && Stopwatch.format(61.25) == "01:01.2")
}

section("防止休眠") {
    let lock = DisplayWakeLock(name: "NotchDeck Checks")
    check("申请", lock.acquire() && lock.isHeld)
    check("重复申请不出错", lock.acquire() && lock.isHeld)
    lock.release()
    check("释放", !lock.isHeld)
    let keepAwake = KeepAwake.shared
    keepAwake.start(minutes: 15)
    check("定时开启", keepAwake.isOn && keepAwake.duration == 15 && keepAwake.minutesLeft == 15)
    keepAwake.start(minutes: nil)
    check("改成一直开着", keepAwake.isOn && keepAwake.duration == nil && keepAwake.minutesLeft == nil)
    keepAwake.stop()
    check("关闭", !keepAwake.isOn)
}

section("待办（临时目录）") {
    Storage.save([TodoStore.Item(id: "a", title: "A"), TodoStore.Item(id: "b", title: "B"), TodoStore.Item(id: "c", title: "C", done: true)], to: "todos.json")
    let store = TodoStore.shared
    store.rename("a", to: "  ")
    check("空白标题不改", store.items.first { $0.id == "a" }?.title == "A")
    store.rename("a", to: "  新标题 ")
    let saved = Storage.load([TodoStore.Item].self, from: "todos.json")?.first { $0.id == "a" }?.title
    check("改名去掉首尾空格并保存", store.items.first { $0.id == "a" }?.title == "新标题" && saved == "新标题")
    check("未完成的本地待办", store.localPendingItems().map(\.id) == ["a", "b"])
    store.removeLocalItems(["a"])
    check("只删除已移交的待办", Storage.load([TodoStore.Item].self, from: "todos.json")?.map(\.id) == ["b", "c"])
}

/// 只比较四项 token 数，费用另外检查。
func tokens(_ counts: TokenCounts?) -> [Int]? { counts.map { [$0.input, $0.cacheRead, $0.cacheWrite, $0.output] } }
func near(_ a: Double?, _ b: Double) -> Bool { a.map { abs($0 - b) < 1e-9 } ?? false }

section("Token 用量解析") {
    check("token 短格式", formatTokens(980) == "980" && formatTokens(12_345) == "12.3K" && formatTokens(1_234_567) == "1.23M" && formatTokens(4_500_000_000) == "4.50B")
    let stamp = "2026-11-10T03:00:00.000Z"
    let day = UsageParsing.dayKey(for: ISO8601DateFormatter().date(from: "2026-11-10T03:00:00Z")!)
    check("时间戳换算成本地日期", UsageParsing.day(fromTimestamp: stamp) == day && UsageParsing.day(fromTimestamp: "2026-11-10T03:00:00Z") == day)

    var claude = UsageFileState(source: .claudeCode)
    var claudeSeen = Set<String>()
    let opus = #"{"type":"assistant","timestamp":"\#(stamp)","message":{"id":"msg_1","model":"claude-opus-5-5","usage":{"input_tokens":10,"cache_read_input_tokens":100,"cache_creation_input_tokens":20,"output_tokens":5}}}"#
    for line in [
        opus, opus,
        #"{"type":"assistant","timestamp":"\#(stamp)","message":{"id":"msg_2","model":"claude-sonnet-5-5","usage":{"input_tokens":1,"output_tokens":2}}}"#,
        #"{"type":"user","timestamp":"\#(stamp)","message":{"role":"user","content":"what is the usage of this?"}}"#,
        #"{"type":"assistant","timestamp":"\#(stamp)","message":{"id":"msg_3","model":"<synthetic>","usage":{"input_tokens":0,"output_tokens":0}}}"#,
        "not json",
    ] { UsageParsing.consume(Data(line.utf8), into: &claude, seen: &claudeSeen) }
    check("Claude Code 重复记录只算一次", tokens(claude.days[day]?["claude-opus-5-5"]) == [10, 100, 20, 5])
    check("Claude Code 按模型分开", tokens(claude.days[day]?["claude-sonnet-5-5"]) == [1, 0, 0, 2])
    check("没有用量的行和空用量被忽略", claude.days[day]?.count == 2)
    var copied = UsageFileState(source: .claudeCode)
    UsageParsing.consume(Data(opus.utf8), into: &copied, seen: &claudeSeen)
    check("复制到别的文件的请求不重复计算", copied.days.isEmpty && copied.ids.isEmpty && claude.ids == ["msg_1", "msg_2", "msg_3"])

    // 扫描器只认 message 里的 usage：对话内容里同名的键、转义的引号和反斜杠都不能干扰。
    var tricky = UsageFileState(source: .claudeCode)
    var trickySeen = Set<String>()
    for line in [
        #"{"timestamp":"\#(stamp)","message":{"id":"t1","model":"claude-opus-5-5","content":[{"type":"tool_use","input":{"usage":{"input_tokens":999},"text":"a \"usage\": {\"x\"} \\"}}],"usage":{"input_tokens":3,"output_tokens":4}}}"#,
        #"{"timestamp":"\#(stamp)","type":"user","message":{"role":"user","content":"x"},"toolUseResult":{"usage":{"input_tokens":50}}}"#,
        #"{"timestamp":"\#(stamp)","message":"hello","usage":{"input_tokens":5}}"#,
        #"{ "timestamp" : "\#(stamp)" , "message" : { "id" : "t2" , "model" : "claude\u002dhaiku-5-5" , "usage" : { "output_tokens" : 1 } } }"#,
        #"{"timestamp":"\#(stamp)","message":{"id":"t3","model":"m","usage":{"input_tokens":1}"#,
    ] { UsageParsing.consume(Data(line.utf8), into: &tricky, seen: &trickySeen) }
    check("对话内容里的同名键和转义字符不影响读取", tokens(tricky.days[day]?["claude-opus-5-5"]) == [3, 0, 0, 4])
    check("带转义的模型名和多余空格也能读", tokens(tricky.days[day]?["claude-haiku-5-5"]) == [0, 0, 0, 1] && tricky.days[day]?.count == 2)
    check("不完整的行被忽略", tricky.ids == ["t1", "t2"])
    let utc = ISO8601DateFormatter()
    check("时间戳快速换算和格式化器一致", ["2026-12-31T23:59:59Z", "2024-02-29T12:00:00.5Z", "2026-01-01T00:00:00.000Z", "2026-07-15T16:30:00Z"].allSatisfy {
        UsageParsing.day(fromTimestamp: $0) == UsageParsing.dayKey(for: utc.date(from: $0.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression))!)
    })
    check("带时区偏移的时间戳交给格式化器，非法日期被忽略", UsageParsing.day(fromTimestamp: "2026-11-10T11:00:00+08:00") == day
          && UsageParsing.day(fromTimestamp: "2026-13-40T00:00:00Z") == nil && UsageParsing.day(fromTimestamp: "2026-11-1xT00:00:00Z") == nil)

    var codex = UsageFileState(source: .codex)
    var codexSeen = Set<String>()
    func tokenCount(_ total: (Int, Int, Int), _ last: (Int, Int, Int)) -> String {
        #"{"timestamp":"\#(stamp)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(total.0),"cached_input_tokens":\#(total.1),"output_tokens":\#(total.2)},"last_token_usage":{"input_tokens":\#(last.0),"cached_input_tokens":\#(last.1),"output_tokens":\#(last.2)}}}}"#
    }
    for line in [
        #"{"timestamp":"\#(stamp)","type":"turn_context","payload":{"model":"gpt-a"}}"#,
        tokenCount((100, 40, 10), (100, 40, 10)),
        tokenCount((100, 40, 10), (100, 40, 10)),
        tokenCount((250, 100, 30), (100, 40, 10)),
        #"{"timestamp":"\#(stamp)","type":"turn_context","payload":{"model":"gpt-b"}}"#,
        tokenCount((50, 0, 5), (50, 0, 5)),
        #"{"timestamp":"\#(stamp)","type":"event_msg","payload":{"type":"token_count","info":null}}"#,
    ] { UsageParsing.consume(Data(line.utf8), into: &codex, seen: &codexSeen) }
    check("Codex 按累计增量计算，重复的累计跳过", tokens(codex.days[day]?["gpt-a"]) == [150, 100, 0, 30])
    check("Codex 累计清零后用单次用量，并跟随模型切换", tokens(codex.days[day]?["gpt-b"]) == [50, 0, 0, 5])

    var resumed = UsageFileState(source: .codex)
    UsageParsing.consume(Data(tokenCount((1_000, 0, 100), (10, 0, 1)).utf8), into: &resumed, seen: &codexSeen)
    check("续接会话的第一条只算单次用量", tokens(resumed.days[day]?["unknown"]) == [10, 0, 0, 1])

    let file = sandbox.appendingPathComponent("partial.jsonl")
    let second = #"{"type":"assistant","timestamp":"\#(stamp)","message":{"id":"msg_9","model":"m","usage":{"input_tokens":7,"output_tokens":3}}}"#
    let firstPart = opus + "\n" + second.prefix(40)
    try? Data(firstPart.utf8).write(to: file)
    var partial = UsageFileState(source: .claudeCode)
    var partialSeen = Set<String>()
    try? UsageParsing.readNewLines(of: file, into: &partial, seen: &partialSeen)
    check("没写完的行留到下次", partial.offset == UInt64(opus.utf8.count + 1) && partial.days[day]?["m"] == nil)
    try? Data((firstPart + second.dropFirst(40) + "\n").utf8).write(to: file)
    try? UsageParsing.readNewLines(of: file, into: &partial, seen: &partialSeen)
    check("Claude Code 按模型价格算费用", near(claude.days[day]?["claude-opus-5-5"]?.cost, 0.000_26))
    var priced = UsageFileState(source: .claudeCode)
    var pricedSeen = Set<String>()
    let fastLine = #"{"timestamp":"\#(stamp)","message":{"id":"fast","model":"claude-opus-5-5","usage":{"input_tokens":0,"cache_creation_input_tokens":1000000,"cache_creation":{"ephemeral_5m_input_tokens":400000,"ephemeral_1h_input_tokens":600000},"output_tokens":0,"speed":"fast","inference_geo":"us"}}}"#
    UsageParsing.consume(Data(fastLine.utf8), into: &priced, seen: &pricedSeen)
    check("缓存写入分 5 分钟和 1 小时，快速模式和美国境内处理加价", near(priced.days[day]?["claude-opus-5-5"]?.cost, 14.96))
    check("按最长前缀找价格", TokenPricing.price(for: "claude-opus-5-5")?.rates.input == 4 && TokenPricing.price(for: "claude-haiku-4-5-20251001")?.rates.input == 1
          && TokenPricing.price(for: "gpt-5.5-pro")?.rates.input == 30 && TokenPricing.price(for: "claude-opus-50") == nil && TokenPricing.price(for: "<synthetic>") == nil)
    check("Haiku 5.5 超过 10 万 token 按长上下文价格", near(TokenPricing.cost(of: TokenUsage(input: 100_000), model: "claude-haiku-5-5"), 0.01)
          && near(TokenPricing.cost(of: TokenUsage(input: 100_001), model: "claude-haiku-5-5"), 0.050_000_5))
    check("OpenAI 输入扣掉缓存，超过 27.2 万按长上下文价格", near(TokenPricing.cost(of: CodexTotals(input: 300_000, cached: 100_000).usage, model: "gpt-5.6-sol"), 1.68))
    check("没有价格的模型费用为 0", codex.days[day]?["gpt-a"]?.cost == 0 && TokenPricing.cost(of: TokenUsage(input: 1), model: "gpt-a") == nil)
    check("美元格式", formatDollars(0) == "$0.00" && formatDollars(0.001) == "<$0.01" && formatDollars(1234.5) == "$1,234.50")
    check("补全后只读新增部分", tokens(partial.days[day]?["m"]) == [7, 0, 0, 3] && partial.days[day]?["claude-opus-5-5"]?.total == 135)
}

section("Token 用量汇总") {
    let claudeRoot = sandbox.appendingPathComponent("claude/projects/demo")
    let codexRoot = sandbox.appendingPathComponent("codex/sessions/2026/11/10")
    try? FileManager.default.createDirectory(at: claudeRoot, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: codexRoot, withIntermediateDirectories: true)
    let now = ISO8601DateFormatter().string(from: Date())
    let claudeFile = claudeRoot.appendingPathComponent("a.jsonl")
    func claudeLine(_ id: String, _ output: Int) -> String {
        #"{"timestamp":"\#(now)","message":{"id":"\#(id)","model":"claude-opus-5-5","usage":{"input_tokens":100,"output_tokens":\#(output)}}}"# + "\n"
    }
    try? Data((claudeLine("a", 50) + claudeLine("a", 50)).utf8).write(to: claudeFile)
    // 恢复或分叉会话时，Claude Code 会把旧记录复制到另一个文件。
    let copyRoot = sandbox.appendingPathComponent("claude/projects/fork")
    try? FileManager.default.createDirectory(at: copyRoot, withIntermediateDirectories: true)
    try? Data(claudeLine("a", 50).utf8).write(to: copyRoot.appendingPathComponent("b.jsonl"))
    try? Data((#"{"timestamp":"\#(now)","type":"turn_context","payload":{"model":"gpt-x"}}"# + "\n" +
               #"{"timestamp":"\#(now)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":0,"output_tokens":10},"last_token_usage":{"input_tokens":1000,"cached_input_tokens":0,"output_tokens":10}}}}"# + "\n").utf8)
        .write(to: codexRoot.appendingPathComponent("rollout.jsonl"))
    // 30 天前就没改过的旧文件不读。
    let oldFile = claudeRoot.appendingPathComponent("old.jsonl")
    try? Data(claudeLine("old", 999).utf8).write(to: oldFile)
    try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-40 * 86_400)], ofItemAtPath: oldFile.path)

    // 旧版本的统计文件在第一次读取时删掉。
    try? Data("{}".utf8).write(to: Storage.folder.appendingPathComponent("token-usage.json"))
    let store = TokenUsageStore.shared
    store.roots = [(sandbox.appendingPathComponent("claude/projects"), .claudeCode), (sandbox.appendingPathComponent("codex/sessions"), .codex)]
    func waitForScan() {
        var done = false
        store.refresh { done = true }
        let limit = Date().addingTimeInterval(10)
        while !done && Date() < limit { pump(0.05) }
    }
    store.isEnabled = true
    pump(0.1)
    let firstLimit = Date().addingTimeInterval(10)
    while (store.isScanning || store.lastUpdated == nil) && Date() < firstLimit { pump(0.05) }
    var rows = store.rows(for: .today)
    check("按用量排序，旧文件跳过，跨文件复制的请求只算一次", rows.map(\.model) == ["gpt-x", "claude-opus-5-5"] && rows.map(\.counts.total) == [1_010, 150])
    check("来源正确", rows.map(\.source) == [.codex, .claudeCode])
    check("汇总费用，没有价格的模型标出来", near(rows.last?.counts.cost, 0.0014) && rows.map(\.isPriced) == [false, true])
    check("删除旧版本的统计文件", !FileManager.default.fileExists(atPath: Storage.folder.appendingPathComponent("token-usage.json").path))

    let handle = try? FileHandle(forWritingTo: claudeFile)
    _ = try? handle?.seekToEnd()
    try? handle?.write(contentsOf: Data(claudeLine("b", 5).utf8))
    try? handle?.close()
    waitForScan()
    rows = store.rows(for: .today)
    check("再次刷新只加新增的用量", rows.first { $0.model == "claude-opus-5-5" }?.counts.total == 255)

    try? Data(claudeLine("c", 1).utf8).write(to: claudeFile)
    waitForScan()
    check("文件被重写后重新统计", store.rows(for: .today).first { $0.model == "claude-opus-5-5" }?.counts.total == 101)
    check("统计结果保存在本机", FileManager.default.fileExists(atPath: Storage.folder.appendingPathComponent(TokenUsageStore.file).path))

    store.isEnabled = false
    pump(0.3)
    check("关闭后清空并删除统计文件", store.days.isEmpty && !FileManager.default.fileExists(atPath: Storage.folder.appendingPathComponent(TokenUsageStore.file).path))
}

section("其他") {
    check("内存压力文字", [MemoryPressure.low, .medium, .high].map(\.title) == [L("压力低"), L("压力中"), L("压力高")])
    check("便签颜色编号不能变", NoteColor.allCases.map(\.rawValue) == [0, 1, 2, 3] && NoteColor(rawValue: 1) == .yellow)
    check("外部命令", Shell.output("/bin/echo", ["hi"]) == Data("hi\n".utf8) && Shell.output("/no/such/command", []) == nil)
    check("不存在的私有函数返回 nil", systemFunction("/usr/lib/libSystem.B.dylib", "NoSuchFunction", as: (@convention(c) () -> Void).self) == nil)
}

try? FileManager.default.removeItem(at: sandbox)
print(failed.isEmpty ? "全部通过：\(passed) 项" : "\(failed.count) 项失败，\(passed) 项通过：\n" + failed.joined(separator: "\n"))
exit(failed.isEmpty ? 0 : 1)
