import Foundation
import SwiftUI

/// Small deterministic RNG so snapshots are reproducible.
struct SplitMix64 {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func unit() -> Double { Double(next() >> 11) / Double(UInt64(1) << 53) }
    mutating func int(_ range: Range<Int>) -> Int { range.lowerBound + Int(next() % UInt64(range.count)) }
    mutating func chance(_ p: Double) -> Bool { unit() < p }
    mutating func pick<T>(_ items: [T]) -> T { items[int(0..<items.count)] }
    mutating func range(_ a: Double, _ b: Double) -> Double { a + (b - a) * unit() }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}

/// 场景每帧都要格式化很多数字，格式器只建一次。
private let groupedFormatter: NumberFormatter = {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    f.groupingSeparator = ","
    return f
}()

func grouped(_ n: Int) -> String {
    groupedFormatter.string(from: NSNumber(value: n)) ?? "\(n)"
}

func duration(_ seconds: Double) -> String {
    let s = Int(seconds)
    if s >= 3600 { return "\(s / 3600)h \((s % 3600) / 60)m" }
    return "\(s / 60)m \(s % 60)s"
}

/// Identifier variants derived from a file name: "invoice-queue.ts" -> InvoiceQueue / invoiceQueue / invoice_queue.
struct Names {
    let pascal: String
    let camel: String
    let snake: String

    init(path: String) {
        let url = URL(fileURLWithPath: path)
        var base = url.deletingPathExtension().lastPathComponent
        if base.hasSuffix(".test") { base = String(base.dropLast(5)) }
        if ["index", "main", "mod", "__init__", "lib", "utils", "types"].contains(base.lowercased()) {
            let parent = url.deletingLastPathComponent().lastPathComponent
            if !parent.isEmpty && parent != "." && parent != "/" { base = parent }
        }
        var words: [String] = []
        var current = ""
        for ch in base {
            if ch.isLetter || ch.isNumber {
                if ch.isUppercase, let last = current.last, last.isLowercase {
                    words.append(current); current = ""
                }
                current.append(ch)
            } else if !current.isEmpty {
                words.append(current); current = ""
            }
        }
        if !current.isEmpty { words.append(current) }
        if words.isEmpty { words = ["core"] }
        if let first = words.first?.first, first.isNumber { words.insert("v", at: 0) }
        let lower = words.map { $0.lowercased() }
        pascal = lower.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
        camel = lower[0] + lower.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
        snake = lower.joined(separator: "_")
    }
}

/// Human-looking typing: variable speed, pauses at line ends and punctuation, auto-indent, the odd typo.
struct Typist {
    private(set) var chars: [Character] = []
    private(set) var typed = 0
    private(set) var typo: Character?
    private var acc = 0.0, pause = 0.0, cps = 20.0, typoLeft = 0.0
    private var speed: ClosedRange<Double> = 14...24

    var isDone: Bool { typed >= chars.count }
    var isActive: Bool { !chars.isEmpty && !isDone }
    var text: String {
        var s = String(chars[0..<min(typed, chars.count)])
        if let t = typo { s.append(t) }
        return s
    }

    mutating func start(_ s: String, speed: ClosedRange<Double>, rng: inout SplitMix64) {
        chars = Array(s)
        typed = 0
        typo = nil
        typoLeft = 0
        acc = 0
        pause = 0.35
        self.speed = speed
        cps = rng.range(speed.lowerBound, speed.upperBound)
        skipIndent()
    }

    mutating func clear() { chars = []; typed = 0; typo = nil }

    private mutating func skipIndent() {
        while typed < chars.count && chars[typed] == " " { typed += 1 }
    }

    mutating func advance(_ dt: Double, rng: inout SplitMix64) {
        guard isActive else { return }
        if typoLeft > 0 {
            typoLeft -= dt
            if typoLeft <= 0 { typo = nil; pause = 0.08 }
            return
        }
        if pause > 0 { pause -= dt; return }
        acc += dt * cps
        while acc >= 1 && typed < chars.count {
            acc -= 1
            let ch = chars[typed]
            typed += 1
            if ch == "\n" {
                skipIndent()
                pause = rng.range(0.1, 0.6)
                cps = rng.range(speed.lowerBound, speed.upperBound)
                acc = 0
                break
            }
            if ".,;:".contains(ch) && rng.chance(0.45) {
                pause = rng.range(0.1, 0.45)
                acc = 0
                break
            }
            if ch.isLetter && rng.chance(0.012) {
                typo = Character(UnicodeScalar(UInt8(97 + rng.int(0..<26))))
                typoLeft = rng.range(0.12, 0.3)
                acc = 0
                break
            }
        }
    }

    /// Someone pressed a key: jump ahead a few characters.
    mutating func boost() {
        guard isActive else { return }
        typo = nil
        typoLeft = 0
        pause = 0
        for _ in 0..<4 where typed < chars.count {
            let ch = chars[typed]
            typed += 1
            if ch == "\n" { skipIndent() }
        }
    }
}
