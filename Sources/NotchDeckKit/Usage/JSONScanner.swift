import Foundation

/// 只按 JSON 结构往前走、不建对象的扫描器。用来在一行记录里跳过对话内容，只取出需要的几个字段，
/// 比把整行交给 JSONSerialization 快得多：对话内容里的大段文字只用 memchr 找结束的引号。
/// 只接受合法的 JSON，遇到不认识的结构就标记失败，调用方放弃这一行。
struct JSONScanner {
    private let base: UnsafePointer<UInt8>
    private let count: Int
    private(set) var index = 0
    private(set) var failed = false

    init(_ bytes: UnsafeRawBufferPointer) {
        base = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self) ?? UnsafePointer(bitPattern: 1)!
        count = bytes.baseAddress == nil ? 0 : bytes.count
    }

    private static let quote = UInt8(ascii: "\"")
    private static let backslash = UInt8(ascii: "\\")

    private var current: UInt8? { index < count ? base[index] : nil }

    private mutating func fail() -> Bool {
        failed = true
        return false
    }

    private mutating func skipWhitespace() {
        while index < count {
            switch base[index] {
            case 0x20, 0x09, 0x0A, 0x0D: index += 1
            default: return
            }
        }
    }

    /// 下一个值是不是对象。
    mutating func atObject() -> Bool {
        skipWhitespace()
        return current == UInt8(ascii: "{")
    }

    /// 当前是对象开头的 { 时进入对象。
    mutating func enterObject() -> Bool {
        skipWhitespace()
        guard current == UInt8(ascii: "{") else { return fail() }
        index += 1
        return true
    }

    /// 读下一个键并停在它的值前面；对象结束时返回 nil。出错时也返回 nil，并把 failed 设为 true。
    mutating func nextKey() -> Range<Int>? {
        skipWhitespace()
        if current == UInt8(ascii: ",") {
            index += 1
            skipWhitespace()
        }
        if current == UInt8(ascii: "}") {
            index += 1
            return nil
        }
        guard let key = stringRange() else { return nil }
        skipWhitespace()
        guard current == UInt8(ascii: ":") else { _ = fail(); return nil }
        index += 1
        skipWhitespace()
        return key
    }

    func key(_ range: Range<Int>, is name: StaticString) -> Bool {
        range.count == name.utf8CodeUnitCount && memcmp(base + range.lowerBound, name.utf8Start, range.count) == 0
    }

    /// 读一个字符串值。带转义的字符串交给 JSONSerialization 解码。值不是字符串时返回 nil，但不算出错。
    mutating func stringValue() -> String? {
        guard current == Self.quote else { _ = skipValue(); return nil }
        let start = index
        guard let range = stringRange() else { return nil }
        let bytes = UnsafeBufferPointer(start: base + range.lowerBound, count: range.count)
        if memchr(base + range.lowerBound, Int32(Self.backslash), range.count) == nil {
            return String(decoding: bytes, as: UTF8.self)
        }
        let raw = Data(bytes: base + start, count: index - start)
        return try? JSONSerialization.jsonObject(with: raw, options: .fragmentsAllowed) as? String
    }

    /// 跳过当前的值，返回它在这一行里的范围。
    @discardableResult
    mutating func skipValue() -> Range<Int>? {
        skipWhitespace()
        let start = index
        guard let first = current else { _ = fail(); return nil }
        switch first {
        case Self.quote:
            guard stringRange() != nil else { return nil }
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            guard skipContainer() else { return nil }
        default:
            // 数字、true、false、null：一直到分隔符为止。
            while index < count {
                switch base[index] {
                case UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]"), 0x20, 0x09, 0x0A, 0x0D: return start..<index
                default: index += 1
                }
            }
        }
        return start..<index
    }

    /// 当前是开头的引号时，返回引号里面的范围，停在结束引号之后。
    private mutating func stringRange() -> Range<Int>? {
        guard current == Self.quote else { _ = fail(); return nil }
        index += 1
        let start = index
        while index < count, let found = memchr(base + index, Int32(Self.quote), count - index) {
            let end = UnsafeRawPointer(base).distance(to: UnsafeRawPointer(found))
            // 前面有奇数个反斜杠时这个引号是转义的，继续往后找。
            var backslashes = 0
            while end - backslashes - 1 >= start, base[end - backslashes - 1] == Self.backslash { backslashes += 1 }
            index = end + 1
            if backslashes % 2 == 0 { return start..<end }
        }
        _ = fail()
        return nil
    }

    /// 跳过对象或数组，里面的字符串整段跳过，只数括号。
    private mutating func skipContainer() -> Bool {
        var depth = 0
        while index < count {
            switch base[index] {
            case Self.quote:
                guard stringRange() != nil else { return false }
                continue
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                depth += 1
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                depth -= 1
                if depth == 0 {
                    index += 1
                    return true
                }
            default:
                break
            }
            index += 1
        }
        return fail()
    }
}
