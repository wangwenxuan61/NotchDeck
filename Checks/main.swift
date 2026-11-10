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

section("其他") {
    check("内存压力文字", [MemoryPressure.low, .medium, .high].map(\.title) == [L("压力低"), L("压力中"), L("压力高")])
    check("便签颜色编号不能变", NoteColor.allCases.map(\.rawValue) == [0, 1, 2, 3] && NoteColor(rawValue: 1) == .yellow)
    check("外部命令", Shell.output("/bin/echo", ["hi"]) == Data("hi\n".utf8) && Shell.output("/no/such/command", []) == nil)
    check("不存在的私有函数返回 nil", systemFunction("/usr/lib/libSystem.B.dylib", "NoSuchFunction", as: (@convention(c) () -> Void).self) == nil)
}

try? FileManager.default.removeItem(at: sandbox)
print(failed.isEmpty ? "全部通过：\(passed) 项" : "\(failed.count) 项失败，\(passed) 项通过：\n" + failed.joined(separator: "\n"))
exit(failed.isEmpty ? 0 : 1)
