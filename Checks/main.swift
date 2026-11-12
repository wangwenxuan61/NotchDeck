import AppKit
import Security
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

section("新功能") {
    let all = ReleaseNotes.all
    check("版本不重复", Set(all.map(\.version)).count == all.count)
    check("最新的写在最前面", zip(all, all.dropFirst()).allSatisfy { $0.version.compare($1.version, options: .numeric) == .orderedDescending })
    check("每个版本一到四条", all.allSatisfy { (1...4).contains($0.items.count) })
    check("找当前版本的", ReleaseNotes.latest(upTo: "0.1.14")?.version == "0.1.14" && ReleaseNotes.notes(for: "0.1.15") != nil)
    check("没写新功能的版本显示之前最近的一份", ReleaseNotes.latest(upTo: "0.1.20")?.version == "0.1.16" && ReleaseNotes.notes(for: "0.1.20") == nil)
    check("按数字比较版本", ReleaseNotes.latest(upTo: "0.1.9") == nil && ReleaseNotes.latest(upTo: "0.1.13") == nil)
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
    // 固定在今天中午，前后几小时都还在今天，结果不会随运行时间变。
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: Date())
    let now = calendar.date(byAdding: .hour, value: 12, to: today)!
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

    let today15 = item("today15", at(day: 0, hour: 15), at(day: 0, hour: 16))
    let tomorrow10 = item("tomorrow10", at(day: 1, hour: 10), at(day: 1, hour: 11))
    let tomorrowAllDay = item("tomorrowAllDay", at(day: 1, hour: 0), at(day: 2, hour: 0), allDay: true)
    let later = item("later", at(day: 3, hour: 9), at(day: 3, hour: 10))
    let week = AgendaStore.upcoming([later, tomorrowAllDay, tomorrow10, item("todayAllDay", today, at(day: 1, hour: 0), allDay: true), today15], at: now)
    check("之后几天的日程按日期排在今天后面", week.map(\.title) == ["today15", "todayAllDay", "tomorrow10", "tomorrowAllDay", "later"])
    check("今天只写时间，明天和之后写上哪天", AgendaStore.whenLabel(today15, at: now) == formatClockTime(today15.start)
          && AgendaStore.whenLabel(tomorrow10, at: now) == L("明天") + " " + formatClockTime(tomorrow10.start)
          && AgendaStore.whenLabel(tomorrowAllDay, at: now) == L("明天") + " " + L("全天")
          && AgendaStore.whenLabel(later, at: now) == localizedDateFormatter("EEE").string(from: at(day: 3, hour: 0)) + " " + formatClockTime(later.start))
    check("一天以后的日程不显示倒计时", AgendaStore.countdown(to: later, at: now) == nil && AgendaStore.countdown(to: today15, at: now) == L("%d 小时后", 3))
    let busy = AgendaStore.busyDays([item("trip", at(day: 1, hour: 0), at(day: 3, hour: 0), allDay: true)])
    check("跨天的日程每一天都标出来，结束那天零点不算", busy == [at(day: 1, hour: 0), at(day: 2, hour: 0)])
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
    check("相同图片", ClipboardStore.isSameContent(.image(thumbnail: NSImage(), data: png, type: .png, size: .zero), .image(thumbnail: NSImage(), data: png, type: .png, size: .zero)))
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
    let png = image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) } ?? Data()
    let text = ClipboardStore.fullImage(png).flatMap(ClipboardStore.recognizeText) ?? ""
    check("识别出文字和数字", text.contains("NotchDeck") && text.contains("2026"))
    let thumbnail = ClipboardStore.thumbnail(of: png)
    let pixels = ClipboardStore.downsample(png, maxPixels: 128).map { max($0.width, $0.height) } ?? 0
    check("列表只解码小缩略图，但记下原图尺寸", pixels > 0 && pixels <= 128 && thumbnail.map { Int($0.1.width) } == NSBitmapImageRep(data: png)?.pixelsWide)
    let subject = NSImage(size: NSSize(width: 600, height: 400))
    subject.lockFocus()
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: 600, height: 400).fill()
    NSColor.systemOrange.setFill()
    NSBezierPath(ovalIn: NSRect(x: 200, y: 100, width: 200, height: 200)).fill()
    subject.unlockFocus()
    let cut = subject.cgImage(forProposedRect: nil, context: nil, hints: nil).flatMap(ClipboardStore.liftSubject).flatMap(ClipboardStore.fullImage)
    check("抠出主体是透明背景、只剩主体大小", cut.map { $0.alphaInfo != .none && $0.alphaInfo != .noneSkipLast && $0.width < 600 } == true)

    let store = ClipboardStore.shared
    let item = ClipboardStore.Item(content: ClipboardStore.imageContent(png, type: .png)!, date: Date(), sourceName: "")
    store.insert(item)
    var waited = 0.0
    while store.imageText[item.id] == nil && waited < 60 { pump(0.5); waited += 0.5 }
    check("图片进来后在后台识别，可以按图里的文字搜索", store.imageText[item.id]?.contains("NotchDeck") == true)
    let previousSave = store.saveHistory
    store.saveHistory = true
    store.persistNow()
    let imageFile = Storage.folder.appendingPathComponent("ClipboardImages/\(item.id.uuidString)")
    let savedJSON = (try? Data(contentsOf: Storage.folder.appendingPathComponent("clipboard.json"))).map { String(decoding: $0, as: UTF8.self) } ?? ""
    check("图片随历史保存成单独的文件", (try? Data(contentsOf: imageFile)) == png && savedJSON.contains(item.id.uuidString) && !savedJSON.contains(png.base64EncodedString()))
    store.remove(item)
    store.persistNow()
    check("删掉图片后识别结果和文件都清掉", store.imageText[item.id] == nil && !FileManager.default.fileExists(atPath: imageFile.path))
    store.saveHistory = previousSave

    let previousBoard = store.pasteboard
    let board = NSPasteboard(name: NSPasteboard.Name("NotchDeckChecks-subject-\(getpid())"))
    store.pasteboard = board
    let photoData = subject.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) } ?? Data()
    let photo = ClipboardStore.Item(content: ClipboardStore.imageContent(photoData, type: .png)!, date: Date(), sourceName: "")
    store.insert(photo)
    store.copySubject(of: photo)
    waited = 0
    while board.data(forType: .png) == nil && waited < 30 { pump(0.5); waited += 0.5 }
    let cutItem = store.items.first { !$0.isPinned }
    check("抠出的主体复制下来并作为新的一条，原图保留", board.data(forType: .png) != nil && cutItem?.id != photo.id
          && store.items.contains { $0.id == photo.id })
    if let cutItem { store.remove(cutItem) }
    store.remove(photo)
    board.releaseGlobally()
    store.pasteboard = previousBoard
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

    // 自动更新重启时：记下状态，新版本启动后恢复，只用一次。
    keepAwake.start(minutes: nil)
    keepAwake.saveForRestart()
    keepAwake.stop()
    keepAwake.restoreAfterRestart()
    check("更新后恢复一直开着", keepAwake.isOn && keepAwake.duration == nil && keepAwake.minutesLeft == nil)
    keepAwake.start(minutes: 240)
    keepAwake.saveForRestart()
    keepAwake.stop()
    keepAwake.restoreAfterRestart()
    check("更新后恢复定时，保留时长和结束时间", keepAwake.isOn && keepAwake.duration == 240 && keepAwake.minutesLeft == 240)
    keepAwake.stop()
    keepAwake.restoreAfterRestart()
    check("记录用一次就删", !keepAwake.isOn)
    UserDefaults.standard.set(["end": Date().addingTimeInterval(-60).timeIntervalSince1970, "duration": 15], forKey: "keepAwakeAfterRestart")
    keepAwake.restoreAfterRestart()
    check("已经过期的定时不恢复", !keepAwake.isOn && UserDefaults.standard.object(forKey: "keepAwakeAfterRestart") == nil)
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
    check("复制到别的文件的请求不重复计算，全是 0 的记录不占用请求 ID", copied.days.isEmpty && copied.ids.isEmpty && claude.ids == ["msg_1", "msg_2"])

    // 同一次请求先记一份 0 或没写完的，再记完整的：要算完整的那份。
    func claudeLine(_ id: String, input: Int, read: Int, output: Int) -> String {
        #"{"timestamp":"\#(stamp)","message":{"id":"\#(id)","model":"claude-opus-5-5","usage":{"input_tokens":\#(input),"cache_read_input_tokens":\#(read),"output_tokens":\#(output)}}}"#
    }
    var repeated = UsageFileState(source: .claudeCode)
    var repeatedSeen = Set<String>()
    var batch: [ClaudeEntry] = []
    for line in [claudeLine("r1", input: 0, read: 0, output: 0), claudeLine("r1", input: 2, read: 800, output: 50),
                 claudeLine("r2", input: 2, read: 500, output: 10), claudeLine("r2", input: 2, read: 500, output: 90), claudeLine("r2", input: 0, read: 0, output: 0)] {
        UsageParsing.consume(Data(line.utf8), into: &repeated, entries: &batch)
    }
    UsageParsing.apply(batch, to: &repeated, seen: &repeatedSeen)
    check("同一次请求记了几遍时算用量最多的那份", tokens(repeated.days[day]?["claude-opus-5-5"]) == [4, 1300, 0, 140] && repeated.ids == ["r1", "r2"])
    var later = UsageFileState(source: .claudeCode)
    UsageParsing.consume(Data(claudeLine("r3", input: 0, read: 0, output: 0).utf8), into: &later, seen: &repeatedSeen)
    UsageParsing.consume(Data(claudeLine("r3", input: 1, read: 0, output: 7).utf8), into: &later, seen: &repeatedSeen)
    check("先读到全是 0 的记录，下次读到的完整记录照样计入", tokens(later.days[day]?["claude-opus-5-5"]) == [1, 0, 0, 7])

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

    // Codex 用 thread_settings_applied 记服务档位，priority 按快速价格（两倍）计。
    func settings(_ model: String, _ tier: String) -> String {
        #"{"timestamp":"\#(stamp)","type":"event_msg","payload":{"type":"thread_settings_applied","thread_settings":{"model":"\#(model)","model_provider_id":"openai","service_tier":"\#(tier)"}}}"#
    }
    var tiered = UsageFileState(source: .codex)
    for line in [settings("gpt-5.6-terra", "priority"), tokenCount((100_000, 0, 0), (100_000, 0, 0)),
                 settings("gpt-5.6-sol", "default"), tokenCount((200_000, 0, 0), (100_000, 0, 0))] {
        UsageParsing.consume(Data(line.utf8), into: &tiered, seen: &codexSeen)
    }
    check("Codex 的 priority 按快速价格计，切回 default 恢复原价，并跟随模型切换",
          near(tiered.days[day]?["gpt-5.6-terra"]?.cost, 0.4) && near(tiered.days[day]?["gpt-5.6-sol"]?.cost, 0.4))
    check("gpt-5.4 和 gpt-5.4-mini 分开计价，gpt-5.5 快速模式 2.5 倍",
          TokenPricing.price(for: "gpt-5.4")?.rates.input == 2.5 && TokenPricing.price(for: "gpt-5.4-mini")?.rates.input == 0.75
          && near(TokenPricing.cost(of: TokenUsage(output: 1_000_000, fast: true), model: "gpt-5.5"), 75))

    // Codex 子代理文件开头分页复制父会话的历史（顺序打乱），之后才是自己的用量：只算后者。
    func meta(_ id: String, forkedFrom parent: String? = nil) -> String {
        let fork = parent.map { #","forked_from_id":"\#($0)""# } ?? ""
        return #"{"timestamp":"\#(stamp)","type":"session_meta","payload":{"id":"\#(id)"\#(fork)}}"#
    }
    let parentID = "019f0000-0000-7000-8000-00000000aaaa", forkID = "019f0000-0000-7000-8000-00000000bbbb"
    let parentFile = sandbox.appendingPathComponent("rollout-parent-\(parentID).jsonl")
    let forkFile = sandbox.appendingPathComponent("rollout-fork-\(forkID).jsonl")
    let parentLines = [meta(parentID), #"{"timestamp":"\#(stamp)","type":"turn_context","payload":{"model":"gpt-5.6-sol"}}"#,
                       tokenCount((100_000, 0, 1_000), (100_000, 0, 1_000)), tokenCount((250_000, 0, 3_000), (150_000, 0, 2_000))]
    let forkLines = [meta(forkID, forkedFrom: parentID), #"{"timestamp":"\#(stamp)","type":"turn_context","payload":{"model":"gpt-5.6-sol"}}"#,
                     tokenCount((250_000, 0, 3_000), (150_000, 0, 2_000)), tokenCount((100_000, 0, 1_000), (100_000, 0, 1_000)),
                     tokenCount((260_000, 0, 3_500), (10_000, 0, 500))]
    try? Data((parentLines.joined(separator: "\n") + "\n").utf8).write(to: parentFile)
    try? Data((forkLines.joined(separator: "\n") + "\n").utf8).write(to: forkFile)
    var parentState = UsageFileState(source: .codex), forkState = UsageFileState(source: .codex), forkSeen = Set<String>()
    try? UsageParsing.readNewLines(of: parentFile, into: &parentState, seen: &forkSeen)
    let copiedTotals = UsageParsing.codexTotals(in: parentFile)
    check("认出 Codex 子代理文件和它的父会话", UsageParsing.codexForkParent(of: forkFile) == parentID && UsageParsing.codexForkParent(of: parentFile) == nil && copiedTotals.count == 2)
    try? UsageParsing.readNewLines(of: forkFile, into: &forkState, seen: &forkSeen, copiedCodexTotals: copiedTotals)
    check("子代理只算自己的用量，复制来的父会话历史不重复算",
          tokens(parentState.days[day]?["gpt-5.6-sol"]) == [250_000, 0, 0, 3_000] && tokens(forkState.days[day]?["gpt-5.6-sol"]) == [10_000, 0, 0, 500])

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

section("自动更新") {
    let release: [String: Any] = ["tag_name": "v9.9.9", "assets": [
        ["name": "notes.txt", "browser_download_url": "https://example.com/notes.txt"],
        ["name": "NotchDeck-9.9.9-x86_64.dmg", "browser_download_url": "https://example.com/x86.dmg"],
        ["name": "NotchDeck-9.9.9-arm64.dmg", "browser_download_url": "https://example.com/arm.dmg", "digest": "sha256:ABCDEF"],
    ]]
    check("优先选 Apple 芯片的 DMG 并读出校验值", UpdateInstaller.dmgAsset(in: release) == .init(url: URL(string: "https://example.com/arm.dmg")!, sha256: "abcdef"))
    check("没有 DMG 或不是 https 时不下载", UpdateInstaller.dmgAsset(in: ["assets": [["name": "a.zip", "browser_download_url": "https://e.com/a.zip"]]]) == nil
          && UpdateInstaller.dmgAsset(in: ["assets": [["name": "a.dmg", "browser_download_url": "http://e.com/a.dmg"]]]) == nil
          && UpdateInstaller.dmgAsset(in: ["assets": [["name": "a.dmg", "browser_download_url": "https://e.com/a.dmg"]]])?.sha256 == nil)

    let folder = sandbox.appendingPathComponent("update")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let abc = folder.appendingPathComponent("abc.txt")
    try? Data("abc".utf8).write(to: abc)
    check("SHA-256", (try? UpdateInstaller.sha256(of: abc)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")

    /// 做一个最小的 App：Info.plist 加一个可执行文件，再做临时签名。
    func makeApp(_ url: URL, id: String, version: String) {
        let contents = url.appendingPathComponent("Contents")
        try? FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        (["CFBundleIdentifier": id, "CFBundleShortVersionString": version, "CFBundleExecutable": "app", "CFBundlePackageType": "APPL"] as NSDictionary)
            .write(to: contents.appendingPathComponent("Info.plist"), atomically: true)
        try? FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: contents.appendingPathComponent("MacOS/app").path)
        _ = Shell.output("/usr/bin/codesign", ["--force", "--sign", "-", url.path])
    }
    let good = folder.appendingPathComponent("Good.app")
    makeApp(good, id: "test.notchdeck", version: "9.9.9")
    func failure(_ body: () throws -> Void) -> UpdateInstaller.Failure? {
        do { try body(); return nil } catch { return error as? UpdateInstaller.Failure }
    }
    check("同一个 App、正确版本、签名完整才算通过", failure { try UpdateInstaller.validate(app: good, bundleID: "test.notchdeck", version: "9.9.9") } == nil
          && failure { try UpdateInstaller.validate(app: good, bundleID: "other.app", version: "9.9.9") } == .wrongApp
          && failure { try UpdateInstaller.validate(app: good, bundleID: "test.notchdeck", version: "9.9.8") } == .wrongApp)
    try? Data("x".utf8).write(to: good.appendingPathComponent("Contents/added.txt"))
    check("签名后被改过的 App 不安装", failure { try UpdateInstaller.validate(app: good, bundleID: "test.notchdeck", version: "9.9.9") } == .signature)

    // 从 DMG 里复制出 App。
    let source = folder.appendingPathComponent("dmg-source")
    makeApp(source.appendingPathComponent("NotchDeck.app"), id: "test.notchdeck", version: "9.9.9")
    let dmg = folder.appendingPathComponent("test.dmg")
    _ = Shell.output("/usr/bin/hdiutil", ["create", "-quiet", "-volname", "NotchDeckTest", "-srcfolder", source.path, "-format", "UDZO", dmg.path])
    let copied = folder.appendingPathComponent("Copied.app")
    check("从 DMG 里复制出 App 并卸载", failure { try UpdateInstaller.copyApp(fromDMG: dmg, mountPoint: folder.appendingPathComponent("mount"), to: copied) } == nil
          && failure { try UpdateInstaller.validate(app: copied, bundleID: "test.notchdeck", version: "9.9.9") } == nil
          && (try? FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("mount").path))?.isEmpty == true)

    // 当前版本用证书签名时，新版本必须是同一个证书签的。
    func requirement(_ text: String) -> SecRequirement? {
        var requirement: SecRequirement?
        return SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess ? requirement : nil
    }
    check("临时签名的 App 没有可比较的证书要求", UpdateInstaller.signingRequirement(of: copied) == nil)
    check("满足当前版本签名要求的新版本可以安装",
          failure { try UpdateInstaller.validate(app: copied, bundleID: "test.notchdeck", version: "9.9.9", requirement: requirement(#"identifier "test.notchdeck""#)) } == nil)
    check("不是同一个证书签名的新版本不安装",
          failure { try UpdateInstaller.validate(app: copied, bundleID: "test.notchdeck", version: "9.9.9",
                                                requirement: requirement(#"identifier "test.notchdeck" and certificate leaf = H"0000000000000000000000000000000000000000""#)) } == .wrongSigner)

    // 替换：新版本放到原位置，旧版本删掉；新版本不存在时原来的 App 保持不动。
    let current = folder.appendingPathComponent("NotchDeck.app")
    makeApp(current, id: "test.notchdeck", version: "1.0")
    try? FileManager.default.copyItem(at: copied, to: folder.appendingPathComponent(".NotchDeck-update-1.app"))
    check("替换后原位置是新版本，没有留下旧版本", failure { try UpdateInstaller.replace(current, with: folder.appendingPathComponent(".NotchDeck-update-1.app")) } == nil
          && failure { try UpdateInstaller.validate(app: current, bundleID: "test.notchdeck", version: "9.9.9") } == nil
          && !((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).contains { $0.hasPrefix(".NotchDeck-") })
    check("新版本不见了就保留原来的 App", failure { try UpdateInstaller.replace(current, with: folder.appendingPathComponent(".NotchDeck-update-missing.app")) } == .replace
          && FileManager.default.fileExists(atPath: current.appendingPathComponent("Contents/Info.plist").path))
    try? FileManager.default.createDirectory(at: folder.appendingPathComponent(".NotchDeck-old-2.app"), withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: folder.appendingPathComponent(".NotchDeck-update-3.app"), withIntermediateDirectories: true)
    UpdateInstaller.removeLeftovers(next: current)
    check("启动时清掉上次没装完的文件", ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasPrefix(".NotchDeck-") }.isEmpty
          && FileManager.default.fileExists(atPath: current.path))

    // 没开“保存历史”时，重启更新也要把这次的剪贴板历史带到新版本。
    let clipboard = ClipboardStore.shared
    let previous = clipboard.saveHistory
    clipboard.saveHistory = false
    clipboard.insert(.init(content: .text("固定内容"), date: Date(), sourceName: "Test", isPinned: true))
    clipboard.insert(.init(content: .text("临时内容"), date: Date(), sourceName: "Test"))
    clipboard.persistForRestart()
    let saved = (try? Data(contentsOf: Storage.folder.appendingPathComponent("clipboard.json"))).map { String(decoding: $0, as: UTF8.self) } ?? ""
    check("更新重启前保存全部剪贴板历史", saved.contains("临时内容") && saved.contains("固定内容") && UserDefaults.standard.bool(forKey: "clipboardKeptForRestart"))
    UserDefaults.standard.removeObject(forKey: "clipboardKeptForRestart")
    clipboard.saveHistory = previous
}

section("剪贴板格式") {
    let html = Data(#"<html><head><style>p{color:red}</style><script>alert(1)</script></head><body><p style="font-family:Arial;color:#f00" class="x"><span style="font-size:20px">Hello <strong>bold</strong> <a href="https://example.com" style="color:blue">link</a> <a href="javascript:alert(1)">bad</a></span></p><ul><li>one</li><li><em>two</em></li></ul><table><tr><td colspan="2" style="background:#eee">cell</td></tr></table><img src="x.png"></body></html>"#.utf8)
    let cleaned = RichTextCleaner.cleanHTML(fromHTML: html) ?? ""
    check("干净格式保留粗体、链接、列表和表格", cleaned.contains("<b>bold</b>") && cleaned.contains(#"<a href="https://example.com">link</a>"#)
          && cleaned.contains("<ul><li>one</li><li><i>two</i></li></ul>") && cleaned.contains(#"<table><tr><td colspan="2">cell </td></tr></table>"#))
    check("干净格式去掉样式、字体、颜色、脚本和图片", !cleaned.contains("style") && !cleaned.contains("class") && !cleaned.contains("Arial")
          && !cleaned.contains("alert") && !cleaned.contains("<img") && !cleaned.contains("<span") && !cleaned.contains("javascript"))

    let attributed = NSMutableAttributedString(string: "Plain ", attributes: [.font: NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor.red])
    attributed.append(NSAttributedString(string: "Bold", attributes: [.font: NSFont.boldSystemFont(ofSize: 18), .backgroundColor: NSColor.yellow]))
    attributed.append(NSAttributedString(string: " site", attributes: [.font: NSFont.systemFont(ofSize: 12), .link: URL(string: "https://example.org")!]))
    let rtf = attributed.rtf(from: NSRange(location: 0, length: attributed.length), documentAttributes: [:]) ?? Data()
    let fromRTF = RichTextCleaner.cleanHTML(from: RichText(rtf: rtf, html: nil)) ?? ""
    check("RTF 也能转成干净格式", fromRTF.contains("<p>Plain <b>Bold</b>") && fromRTF.contains(#"<a href="https://example.org"> site</a>"#)
          && !fromRTF.contains("color") && !fromRTF.contains("font"))

    let store = ClipboardStore.shared
    let previousBoard = store.pasteboard
    let board = NSPasteboard(name: NSPasteboard.Name("NotchDeckChecks-\(getpid())"))
    store.pasteboard = board
    let item = ClipboardStore.Item(content: .text("Hello bold"), date: Date(), sourceName: "Test", rich: RichText(rtf: rtf, html: html))
    store.copy(item, style: .original)
    check("原格式：文字、RTF、HTML 都放回剪贴板", board.string(forType: .string) == "Hello bold" && board.data(forType: .rtf) == rtf && board.data(forType: .html) == html)
    store.copy(item, style: .plain)
    check("纯文本：只放文字", board.string(forType: .string) == "Hello bold" && board.data(forType: .rtf) == nil && board.data(forType: .html) == nil)
    store.copy(item, style: .clean)
    let cleanOnBoard = board.data(forType: .html).map { String(decoding: $0, as: UTF8.self) } ?? ""
    check("干净格式：放不带样式的 HTML 和文字", board.data(forType: .rtf) == nil && cleanOnBoard.contains("<b>bold</b>") && !cleanOnBoard.contains("style")
          && board.string(forType: .string) == "Hello bold")
    let previousDefault = store.copiesPlainByDefault
    store.copiesPlainByDefault = false
    let defaultOriginal = store.defaultStyle() == .original && store.defaultStyle(inverted: true) == .plain
    store.copiesPlainByDefault = true
    check("默认复制方式和 ⇧ 反转", defaultOriginal && store.defaultStyle() == .plain && store.defaultStyle(inverted: true) == .original)
    store.copiesPlainByDefault = previousDefault
    check("空的格式不算带格式", !ClipboardStore.Item(content: .text("x"), date: Date(), sourceName: "", rich: RichText()).hasFormatting && item.hasFormatting)

    // 保存历史时格式也一起保存。
    let previousSave = store.saveHistory
    store.saveHistory = true
    store.insert(item)
    store.persistNow()
    let saved = (try? Data(contentsOf: Storage.folder.appendingPathComponent("clipboard.json"))).map { String(decoding: $0, as: UTF8.self) } ?? ""
    check("格式随历史一起保存", saved.contains("\"rtf\"") && saved.contains("\"html\""))
    store.remove(item)

    let old = ClipboardStore.Item(content: .text(#"{"city":"Paris","temp":18}"#), date: Date(timeIntervalSinceNow: -3_600), sourceName: "")
    store.insert(old)
    pump(1)
    check("整理推荐在后台提前算好", store.suggestionCache[old.id]?.map(\.id) == ["json"])
    store.copy(old, style: .plain)
    check("重新复制时排到最前并更新时间", store.items.first { !$0.isPinned }?.id == old.id && abs(store.items.first { $0.id == old.id }?.date.timeIntervalSinceNow ?? -100) < 5)
    store.remove(old)
    store.saveHistory = previousSave
    store.persistNow()
    board.releaseGlobally()
    store.pasteboard = previousBoard
}

section("剪贴板智能整理") {
    typealias T = TextTransforms
    func ids(_ text: String, source: String = "") -> [String] { T.suggestions(for: text, source: source).map(\.id) }

    check("JSON 格式化保留键的顺序", T.json(#"{"b":1,"a":[1,{"c":"x,y"}],"e":{}}"#, pretty: true)
          == "{\n  \"b\": 1,\n  \"a\": [\n    1,\n    {\n      \"c\": \"x,y\"\n    }\n  ],\n  \"e\": {}\n}")
    check("JSON 压缩成一行", T.json("{\n  \"a\": [1, 2]\n}", pretty: false) == #"{"a":[1,2]}"#)
    check("挤在一起的 JSON 只推荐格式化，排好的只推荐压缩", ids(#"{"a":1}"#) == ["json"] && ids("{\n  \"a\": 1\n}") == ["json-min"])
    check("不是 JSON 不推荐", T.json("{not json}", pretty: true) == nil)
    check("XML 格式化且不加声明", T.xml("<a><b>1</b></a>")?.hasPrefix("<a>") == true && T.xml("<a><b>1</b></a>")?.contains("\n") == true)

    let table = "名称\t数量\nA_1\t3\nB|2\t4\nC#\t50%"
    check("表格转 Markdown", T.table(table, as: .markdown) == "| 名称 | 数量 |\n| --- | --- |\n| A_1 | 3 |\n| B\\|2 | 4 |\n| C# | 50% |")
    let latex = T.table(table, as: .latex) ?? ""
    check("表格转 LaTeX 并转义", latex.hasPrefix(#"\begin{tabular}{ll}"#) && latex.contains(#"A\_1 & 3 \\"#) && latex.contains(##"C\# & 50\% \\"##))
    check("表格转 CSV", T.table("a\tb\nx,1\t\"q\"", as: .csv) == "a,b\n\"x,1\",\"\"\"q\"\"\"")
    check("Tab 缩进的代码不算表格", T.table("\tfoo()\n\tbar()", as: .markdown) == nil)

    check("去转义，包括 emoji 的代理项", T.unescape(#"第一行\n\"引号\" 中文 😀"#) == "第一行\n\"引号\" 中文 😀")
    check("URL 解码", T.urlDecode("q=%E4%B8%AD%E6%96%87") == "q=中文" && T.urlDecode("100% sure") == nil)
    check("时间戳", T.timestamp("1731234567") != nil && T.timestamp("1731234567000") == T.timestamp("1731234567") && T.timestamp("12345") == nil && T.timestamp("9999999999") == nil)

    check("分享口令只留链接", T.onlyLink("【淘宝】限时特惠 https://m.tb.cn/h.abc 打开手机淘宝") == "https://m.tb.cn/h.abc" && T.onlyLink("https://example.com") == nil)
    check("去掉跟踪参数，保留正常参数", T.stripTracking("看 https://x.com/item?id=1&utm_source=wx&spm=a.b 这个") == "看 https://x.com/item?id=1 这个"
          && T.stripTracking("https://x.com/item?id=1") == nil)

    let pdf = "The results show that the pro-\nposed method improves the accuracy of\nsegmentation on all datasets."
    check("PDF 断行合并，去掉断词连字符", T.mergeLines(pdf) == "The results show that the proposed method improves the accuracy of segmentation on all datasets.")
    check("中文断行合并不加空格", T.mergeLines("这是第一行\n接着第二行") == "这是第一行接着第二行")
    check("PDF 文字推荐合并，列表不推荐", ids(pdf).contains("merge") && !ids("- 苹果\n- 香蕉", source: "预览").contains("merge"))

    check("去掉连续行号", T.removeLineNumbers(["1  import os", "2  print(1)", "3  x = 2"]) == "import os\nprint(1)\nx = 2" && T.removeLineNumbers(["1 a", "3 b", "4 c"]) == nil)
    check("去掉编号和项目符号", T.removeListMarkers(["1. 苹果", "2. 香蕉"]) == "苹果\n香蕉" && T.removeListMarkers(["• a", "普通一行"]) == nil)
    check("短行列表去空行，文章分段不动", T.removeBlankLines(["a", "", "b"]) == "a\nb"
          && T.removeBlankLines([String(repeating: "长句子", count: 30), "", String(repeating: "长句子", count: 30)]) == nil)
    check("去掉重复行", T.removeDuplicateLines(["a", "b", "a"]) == "a\nb" && T.removeDuplicateLines(["a", "b", "c"]) == nil)

    check("中英文之间加空格", T.spaceCJK("使用Python处理3组数据") == "使用 Python 处理 3 组数据" && T.spaceCJK("使用 Python 处理") == nil)
    check("中文标点，小数和网址不受影响", T.chinesePunctuation("你好,世界.价格是3.5元(含税)") == "你好，世界。价格是3.5元（含税）")
    check("英文标点", T.englishPunctuation("Hello，world。This is （a） test？") == "Hello, world. This is (a) test?")
    check("论文标题大小写", T.titleCase("a novel method for image segmentation with U-Net and iPhone data")
          == "A Novel Method for Image Segmentation with U-Net and iPhone Data" && T.titleCase("A NOVEL METHOD") == "A Novel Method")
    check("句子和已是标题的不推荐标题大小写", T.titleCase("This is a sentence.") == nil && T.titleCase("A Novel Method") == nil)

    check("JSON 和带符号的文字不推荐标题大小写", T.titleCase(#"{"name":"NotchDeck","tags":{}}"#) == nil && T.titleCase("see https://example.com now") == nil)
    check("转义文字不推荐中英文加空格", T.spaceCJK(#"第一行\t缩进"#) == nil)
    check("编号列表推荐去编号而不是去行号", ids("1. 整理数据\n2. 跑实验\n3. 写讨论") == ["list-markers"])
    check("普通聊天内容没有任何推荐", ids("明天下午三点开会，记得带电脑。").isEmpty && ids("ok").isEmpty)
    check("结果相同的推荐只留一个", Set(ids("1. a\n2. b\n3. c")).count == ids("1. a\n2. b\n3. c").count)
}

section("正在播放的辅助进程") {
    // 读取正在播放的 osascript 只在面板打开时运行，关掉后不能留下进程，也不能因为很快关了又开而多出一个。
    func helpers() -> Int {
        let data = Shell.output("/usr/bin/pgrep", ["-P", String(getpid()), "osascript"]) ?? Data()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").count
    }
    let media = MediaController.shared
    check("一开始没有运行", helpers() == 0)
    media.start()
    pump(0.5)
    check("打开后运行一个", helpers() == 1)
    media.stop()
    pump(0.5)
    check("关掉后退出", helpers() == 0)
    media.start()
    media.stop()
    media.start()
    pump(2)
    check("很快关了又开，只留一个", helpers() == 1)
    media.stop()
    pump(1.5)
    check("关掉后不会自己重启", helpers() == 0)
}

section("首页卡片") {
    let layout = CardLayoutStore.shared
    check("时间在顶栏，默认不放时钟卡片", !layout.pages.joined().contains(.clock) && layout.hidden.contains(.clock))
    check("待办和短记默认在第一页最前面", Array(layout.pages[0].prefix(2)) == [.todo, .note])
    check("第二页默认是日程、剪贴板、暂存架、今日用时", layout.pages[1] == [.agenda, .clipboard, .shelf, .appTime]
          && layout.hidden.contains(.calendar) && layout.hidden.contains(.lookBusy) && layout.hidden.contains(.timer))
    let old: [[CardKind]] = [[.todo, .note, .monitor, .music], [.agenda, .clipboard, .timer, .calendar, .lookBusy]]
    check("已有布局拿掉月历和装忙卡片，暂存架放在剪贴板后面",
          CardLayoutStore.useScheduleAndShelf(old) == [[.todo, .note, .monitor, .music], [.agenda, .clipboard, .shelf, .timer]])
    check("剪贴板那页满了就放到空出来的位置，已经有暂存架就不再加",
          CardLayoutStore.useScheduleAndShelf([[.clipboard, .todo, .note, .monitor, .music], [.timer, .calendar]]) == [[.clipboard, .todo, .note, .monitor, .music], [.timer, .shelf]]
          && CardLayoutStore.useScheduleAndShelf([[.shelf, .calendar], [.lookBusy]]) == [[.shelf], []])
}

section("今日用时") {
    let usage = AppUsageStore.shared
    usage.reset()
    let base = Calendar.current.date(byAdding: .hour, value: 10, to: Calendar.current.startOfDay(for: Date()))!
    func at(_ seconds: Double) -> Date { base.addingTimeInterval(seconds) }
    func seconds(_ app: String) -> Double { usage.usage(on: base).first { $0.app == app }?.seconds ?? 0 }
    usage.unpause(at: at(0))
    usage.activate("com.example.a", at: at(0), idle: 0)
    usage.record(until: at(60), idle: 3)
    usage.activate("com.example.b", at: at(90), idle: 0)
    check("切换 App 时把之前的时间算给上一个", seconds("com.example.a") == 90)
    usage.record(until: at(990), idle: 900)
    check("很久没操作只算到停下后 5 分钟", seconds("com.example.b") == 300)
    usage.record(until: at(1_050), idle: 0)
    usage.pause(at: at(1_110))
    usage.record(until: at(5_000), idle: 0)
    usage.unpause(at: at(5_000))
    usage.record(until: at(5_060), idle: 0)
    check("锁屏或休眠期间不算", seconds("com.example.b") == 300 + 120 + 60)
    usage.activate("com.apple.loginwindow", at: at(5_100), idle: 0)
    usage.record(until: at(5_400), idle: 0)
    check("锁屏界面不算 App，用得多的排前面", seconds("com.apple.loginwindow") == 0 && usage.usage(on: base).map(\.app) == ["com.example.b", "com.example.a"])
    usage.reset()
}

section("暂存架") {
    let shelf = ShelfStore.shared
    shelf.clear()
    let folder = sandbox.appendingPathComponent("shelf", isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let files = (0..<14).map { folder.appendingPathComponent("f\($0).txt") }
    for file in files { try? Data("x".utf8).write(to: file) }
    shelf.add([files[0], files[1]])
    shelf.add([files[0]])
    check("重复放进来的移到最前面，不重复", shelf.paths == [files[0].path, files[1].path])
    shelf.add([URL(string: "https://example.com")!])
    check("只收文件", shelf.paths.count == 2)
    shelf.add(Array(files[2...]))
    check("最多留 12 个，最近的在前面", shelf.paths.count == ShelfStore.limit && shelf.paths.first == files[2].path)
    try? FileManager.default.removeItem(at: files[2])
    shelf.pruneMissing()
    check("文件被删掉后自动去掉", !shelf.paths.contains(files[2].path) && shelf.paths.count == ShelfStore.limit - 1)
    shelf.remove(files[3].path)
    check("可以单独移除", !shelf.paths.contains(files[3].path))
    shelf.clear()
    check("清空", shelf.paths.isEmpty)
}

section("其他") {
    check("内存压力文字", [MemoryPressure.low, .medium, .high].map(\.title) == [L("压力低"), L("压力中"), L("压力高")])
    check("便签颜色编号不能变", NoteColor.allCases.map(\.rawValue) == [0, 1, 2, 3] && NoteColor(rawValue: 1) == .yellow)
    check("外部命令", Shell.output("/bin/echo", ["hi"]) == Data("hi\n".utf8) && Shell.output("/no/such/command", []) == nil)
    check("不存在的私有函数返回 nil", systemFunction("/usr/lib/libSystem.B.dylib", "NoSuchFunction", as: (@convention(c) () -> Void).self) == nil)
}

try? FileManager.default.removeItem(at: sandbox)
// 设置由系统的 cfprefsd 写到真实的 ~/Library/Preferences，不受上面的 CFFIXED_USER_HOME 影响。
// 文件会留下，但把检查写过的值清空，下次检查也从默认设置开始。
UserDefaults.standard.removePersistentDomain(forName: ProcessInfo.processInfo.processName)
print(failed.isEmpty ? "全部通过：\(passed) 项" : "\(failed.count) 项失败，\(passed) 项通过：\n" + failed.joined(separator: "\n"))
exit(failed.isEmpty ? 0 : 1)
