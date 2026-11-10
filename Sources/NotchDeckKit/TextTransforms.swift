import Foundation

/// 一条整理建议：菜单里显示 title，点了复制 result。
struct Suggestion: Identifiable {
    let id: String
    let title: String
    let result: String
}

/// 认出剪贴板文字是什么，只给出“内容符合、整理后确实有变化”的整理方式，认不出就什么都不给。
/// 每种整理都是独立的纯函数，内容不符合时返回 nil。
enum TextTransforms {
    /// 太长的文字不做判断，免得打开右键菜单时卡住。
    private static let maxBytes = 200_000

    static func suggestions(for text: String, source: String = "") -> [Suggestion] {
        guard text.utf8.count <= maxBytes else { return [] }
        let lines = text.components(separatedBy: .newlines)
        let time = timestamp(text)
        let candidates: [(String, String, String?)] = [
            ("time", L("转成时间 %@", time ?? ""), time),
            ("json", L("格式化 JSON"), json(text, pretty: true).flatMap { $0.components(separatedBy: "\n").count > lines.count * 2 ? $0 : nil }),
            ("json-min", L("压缩 JSON 成一行"), lines.count > 1 ? json(text, pretty: false) : nil),
            ("xml", L("格式化 XML"), xml(text)),
            ("markdown-table", L("转成 Markdown 表格"), table(text, as: .markdown)),
            ("latex-table", L("转成 LaTeX 表格"), table(text, as: .latex)),
            ("csv", L("转成 CSV"), table(text, as: .csv)),
            ("unescape", L("去掉转义"), unescape(text)),
            ("url-decode", L("URL 解码"), urlDecode(text)),
            ("only-link", L("只保留链接"), onlyLink(text)),
            ("tracking", L("去掉链接跟踪参数"), stripTracking(text)),
            ("merge", L("合并成段落"), looksLikeBrokenLines(lines, source: source) ? mergeLines(text) : nil),
            ("line-numbers", L("去掉行号"), removeLineNumbers(lines)),
            ("list-markers", L("去掉编号和项目符号"), removeListMarkers(lines)),
            ("blank-lines", L("去掉空行"), removeBlankLines(lines)),
            ("duplicates", L("去掉重复行"), removeDuplicateLines(lines)),
            ("cjk-space", L("中英文之间加空格"), spaceCJK(text)),
            ("chinese-punctuation", L("转成中文标点"), chinesePunctuation(text)),
            ("english-punctuation", L("转成英文标点"), englishPunctuation(text)),
            ("title-case", L("英文标题大小写"), titleCase(text)),
        ]
        var seen: Set<String> = [text]
        return candidates.compactMap { id, title, result in
            guard let result, seen.insert(result).inserted else { return nil }
            return Suggestion(id: id, title: title, result: result)
        }
    }

    // MARK: - 数据

    /// 10 位秒或 13 位毫秒，落在 2000 到 2100 年之间才算时间戳。
    static func timestamp(_ text: String) -> String? {
        let digits = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard digits.count == 10 || digits.count == 13, digits.allSatisfy(\.isASCIIDigit), let value = Double(digits) else { return nil }
        let seconds = digits.count == 13 ? value / 1000 : value
        guard (946_684_800...4_102_444_800).contains(seconds) else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date(timeIntervalSince1970: seconds))
    }

    /// 只重新排空白，不改键的顺序（JSONSerialization 重新输出会打乱顺序）。
    static func json(_ text: String, pretty: Bool) -> String? {
        let source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard source.first == "{" || source.first == "[",
              (try? JSONSerialization.jsonObject(with: Data(source.utf8))) != nil else { return nil }
        var output = "", depth = 0, inString = false, escaped = false
        func newline() { if pretty { output += "\n" + String(repeating: "  ", count: depth) } }
        for character in source {
            if inString {
                output.append(character)
                if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { inString = false }
                continue
            }
            switch character {
            case "\"": inString = true; output.append(character)
            case "{", "[": output.append(character); depth += 1; newline()
            case "}", "]": depth -= 1; newline(); output.append(character)
            case ",": output.append(character); newline()
            case ":": output += pretty ? ": " : ":"
            case _ where character.isWhitespace: continue
            default: output.append(character)
            }
        }
        // 空对象和空数组保持在一行。
        return output.replacingOccurrences(of: #"([\[{])\s+([\]}])"#, with: "$1$2", options: .regularExpression)
    }

    static func xml(_ text: String) -> String? {
        let source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard source.hasPrefix("<"), let document = try? XMLDocument(xmlString: source) else { return nil }
        let pretty = document.xmlString(options: .nodePrettyPrint)
        // 原文没有 XML 声明时不加。
        guard !source.hasPrefix("<?xml") else { return pretty }
        return pretty.replacingOccurrences(of: #"^<\?xml[^>]*\?>\s*"#, with: "", options: .regularExpression)
    }

    enum TableFormat { case markdown, latex, csv }

    /// 从 Excel、Numbers、网页复制的表格是制表符分隔的多行，每行列数相同。
    static func table(_ text: String, as format: TableFormat) -> String? {
        let rows = text.components(separatedBy: .newlines).filter { !$0.isEmpty }.map { $0.components(separatedBy: "\t") }
        // 表头每格都有内容，排除用 Tab 缩进的代码（每行开头是一个空列）。
        guard rows.count >= 2, let header = rows.first, header.count >= 2, !header.contains(where: \.isEmpty),
              rows.allSatisfy({ $0.count == header.count }) else { return nil }
        let columns = header.count
        switch format {
        case .markdown:
            let line = { (cells: [String]) in "| " + cells.map { $0.replacingOccurrences(of: "|", with: #"\|"#) }.joined(separator: " | ") + " |" }
            return ([line(rows[0]), line(Array(repeating: "---", count: columns))] + rows.dropFirst().map(line)).joined(separator: "\n")
        case .latex:
            let special: [Character: String] = ["\\": "\\textbackslash{}", "&": "\\&", "%": "\\%", "$": "\\$", "#": "\\#", "_": "\\_",
                                                "{": "\\{", "}": "\\}", "~": "\\textasciitilde{}", "^": "\\textasciicircum{}"]
            let escape = { (cell: String) in cell.map { special[$0] ?? String($0) }.joined() }
            let body = rows.map { $0.map(escape).joined(separator: " & ") + #" \\"# }
            return ([#"\begin{tabular}{"# + String(repeating: "l", count: columns) + "}", #"\hline"#, body[0], #"\hline"#]
                    + body.dropFirst() + [#"\hline"#, #"\end{tabular}"#]).joined(separator: "\n")
        case .csv:
            let field = { (cell: String) in
                cell.contains(where: { ",\"\n".contains($0) }) ? "\"" + cell.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : cell
            }
            return rows.map { $0.map(field).joined(separator: ",") }.joined(separator: "\n")
        }
    }

    private static let escapePattern = #"\\([ntr"\\/]|u[0-9a-fA-F]{4})"#

    /// 把 \n、\t、\"、\\、\uXXXX 还原成真正的字符，常见于日志和 JSON 字符串。
    static func unescape(_ text: String) -> String? {
        guard text.range(of: escapePattern, options: .regularExpression) != nil else { return nil }
        let mapped: [Character: Character] = ["n": "\n", "t": "\t", "r": "\r", "\"": "\"", "\\": "\\", "/": "/"]
        var output = "", units: [UInt16] = []
        var index = text.startIndex
        func flushUnits() { output += String(decoding: units, as: UTF16.self); units = [] }
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            guard character == "\\", next < text.endIndex else { flushUnits(); output.append(character); index = next; continue }
            let code = text[next]
            if code == "u", let end = text.index(next, offsetBy: 5, limitedBy: text.endIndex),
               let unit = UInt16(text[text.index(after: next)..<end], radix: 16) {
                units.append(unit)   // 连续的 \u 可能是一对代理项，攒齐再解码
                index = end
                continue
            }
            flushUnits()
            output.append(mapped[code] ?? character)
            index = mapped[code] == nil ? next : text.index(after: next)
        }
        flushUnits()
        return output
    }

    static func urlDecode(_ text: String) -> String? {
        guard text.range(of: "%[0-9A-Fa-f]{2}", options: .regularExpression) != nil else { return nil }
        return text.removingPercentEncoding
    }

    // MARK: - 链接

    private static func links(in text: String) -> [NSTextCheckingResult] {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        return detector?.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .filter { ["http", "https"].contains($0.url?.scheme?.lowercased() ?? "") } ?? []
    }

    /// 淘宝、B 站等分享口令：一段文字里只夹着一个链接。
    static func onlyLink(_ text: String) -> String? {
        let found = links(in: text)
        guard found.count == 1, let range = Range(found[0].range, in: text) else { return nil }
        let rest = text.replacingCharacters(in: range, with: "").filter { !$0.isWhitespace }
        return rest.count >= 4 ? String(text[range]) : nil
    }

    private static let trackingNames: Set<String> = [
        "spm", "scm", "fbclid", "gclid", "igshid", "si", "vd_source", "share_source", "share_medium", "share_plat",
        "share_session_id", "share_tag", "share_from", "unique_k", "sharer_sharetime", "sharer_shareid", "is_copy_url", "is_from_webapp",
    ]

    static func stripTracking(_ text: String) -> String? {
        var output = text
        for match in links(in: text).reversed() {
            guard let range = Range(match.range, in: output), var components = URLComponents(string: String(output[range])),
                  let items = components.queryItems else { continue }
            let kept = items.filter { !trackingNames.contains($0.name.lowercased()) && !$0.name.lowercased().hasPrefix("utm_") }
            guard kept.count < items.count else { continue }
            components.queryItems = kept.isEmpty ? nil : kept
            if let cleaned = components.string { output.replaceSubrange(range, with: cleaned) }
        }
        return output == text ? nil : output
    }

    // MARK: - 段落和行

    private static let pdfReaders = ["preview", "预览", "預覽", "acrobat", "zotero", "pdf", "skim"]
    private static let sentenceEnd = Set(".!?。！？:：;；")

    /// 从 PDF 阅读器复制的，或者有一半以上的换行断在句子中间（下一行以小写字母或汉字开头）。
    static func looksLikeBrokenLines(_ lines: [String], source: String) -> Bool {
        let content = lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard content.count >= 2, removeListMarkers(lines) == nil else { return false }
        if pdfReaders.contains(where: source.lowercased().contains) { return true }
        let breaks = zip(content, content.dropFirst()).filter { line, next in
            guard let last = line.last, let first = next.first else { return false }
            return !sentenceEnd.contains(last) && (first.isLowercase || first.isCJK)
        }
        let averageLength = content.reduce(0) { $0 + $1.count } / content.count
        return averageLength >= 30 && breaks.count * 2 >= content.count - 1
    }

    /// 段落内的行接起来：英文断词去掉连字符，中文之间不加空格，其余加一个空格。空行仍然分段。
    static func mergeLines(_ text: String) -> String? {
        let paragraphs = text.components(separatedBy: .newlines).split(whereSeparator: { $0.trimmingCharacters(in: .whitespaces).isEmpty })
        let merged = paragraphs.map { paragraph in
            paragraph.map { $0.trimmingCharacters(in: .whitespaces) }.reduce(into: "") { result, line in
                guard let last = result.last, let first = line.first else { result += line; return }
                if last == "-", first.isLowercase, result.dropLast().last?.isLetter == true {
                    result.removeLast()
                    result += line
                } else {
                    result += (last.isCJK || first.isCJK ? "" : " ") + line
                }
            }
        }
        return merged.joined(separator: "\n\n")
    }

    /// 每行开头是连续递增的数字，比如从网页或 PDF 复制的代码。
    static func removeLineNumbers(_ lines: [String]) -> String? {
        let content = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        // “1.”“1)”是列表编号，留给 removeListMarkers。
        let pattern = #"^\s*(\d+)[\s:|]\s?"#
        let numbers = content.compactMap { line in line.range(of: pattern, options: .regularExpression).flatMap { Int(line[$0].filter(\.isNumber)) } }
        guard content.count >= 3, numbers.count == content.count, zip(numbers, numbers.dropFirst()).allSatisfy({ $1 == $0 + 1 }) else { return nil }
        return content.map { $0.replacingOccurrences(of: pattern, with: "", options: .regularExpression) }.joined(separator: "\n")
    }

    static func removeListMarkers(_ lines: [String]) -> String? {
        let content = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let pattern = #"^\s*([-*•·▪◦‣]|\d+[.、)]|[a-zA-Z][.)])\s+"#
        guard content.count >= 2, content.allSatisfy({ $0.range(of: pattern, options: .regularExpression) != nil }) else { return nil }
        return content.map { $0.replacingOccurrences(of: pattern, with: "", options: .regularExpression) }.joined(separator: "\n")
    }

    /// 只对列表一类的短行生效，正常文章的分段空行不动。
    static func removeBlankLines(_ lines: [String]) -> String? {
        let content = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard content.count >= 2, content.count < lines.count, content.reduce(0, { $0 + $1.count }) / content.count < 60 else { return nil }
        return content.joined(separator: "\n")
    }

    static func removeDuplicateLines(_ lines: [String]) -> String? {
        var seen = Set<String>()
        let unique = lines.filter { $0.trimmingCharacters(in: .whitespaces).isEmpty || seen.insert($0).inserted }
        return unique.count < lines.count && lines.count >= 3 ? unique.joined(separator: "\n") : nil
    }

    // MARK: - 中英文

    static func spaceCJK(_ text: String) -> String? {
        // 转义文字里的 \t、\n 会被误当成英文字母。
        guard text.range(of: escapePattern, options: .regularExpression) == nil else { return nil }
        let spaced = text
            .replacingOccurrences(of: #"(\p{Han})([A-Za-z0-9])"#, with: "$1 $2", options: .regularExpression)
            .replacingOccurrences(of: #"([A-Za-z0-9])(\p{Han})"#, with: "$1 $2", options: .regularExpression)
        return spaced == text ? nil : spaced
    }

    private static func counts(_ text: String) -> (han: Int, latin: Int) {
        text.reduce(into: (0, 0)) { if $1.isCJK { $0.0 += 1 } else if $1.isASCII && $1.isLetter { $0.1 += 1 } }
    }

    /// 以中文为主的文字里，挨着汉字的英文标点换成中文标点。小数点、网址里的标点不挨着汉字，不受影响。
    static func chinesePunctuation(_ text: String) -> String? {
        let (han, latin) = counts(text)
        guard han > latin else { return nil }
        let map: [String: String] = [",": "，", ".": "。", "?": "？", "!": "！", ":": "：", ";": "；"]
        var output = text.replacingOccurrences(of: #"\(([^()\n]*\p{Han}[^()\n]*)\)"#, with: "（$1）", options: .regularExpression)
        let pattern = try? NSRegularExpression(pattern: #"(?<=\p{Han})[,.?!:;]\s*|[,.?!:;](?=\p{Han})"#)
        for match in pattern?.matches(in: output, range: NSRange(output.startIndex..., in: output)).reversed() ?? [] {
            guard let range = Range(match.range, in: output) else { continue }
            output.replaceSubrange(range, with: map[String(output[range].prefix(1))] ?? "")
        }
        return output == text ? nil : output
    }

    /// 以英文为主的文字里，中文标点换成英文标点并补上空格。
    static func englishPunctuation(_ text: String) -> String? {
        let (han, latin) = counts(text)
        guard latin > han * 3 else { return nil }
        let map: [Character: String] = ["，": ", ", "。": ". ", "？": "? ", "！": "! ", "：": ": ", "；": "; ", "、": ", ",
                                        "（": " (", "）": ") ", "“": "\"", "”": "\"", "‘": "'", "’": "'"]
        guard text.contains(where: { map[$0] != nil }) else { return nil }
        return text.map { map[$0] ?? String($0) }.joined()
            .replacingOccurrences(of: #" +([,.?!:;)])"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #" {2,}"#, with: " ", options: .regularExpression)
            .components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
    }

    private static let minorWords: Set<String> = [
        "a", "an", "the", "and", "but", "or", "nor", "for", "so", "yet", "as", "at", "by", "in", "of", "on", "per", "to",
        "up", "via", "vs", "with", "from", "into", "onto", "over",
    ]

    /// 一行英文、不以句号结尾、2 到 25 个词，按论文标题的规则：首尾词和实词首字母大写，冠词、短介词、连词小写，
    /// 本来就有内部大写的词（iPhone、CNN、U-Net）保持原样。
    static func titleCase(_ text: String) -> String? {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = line.split(separator: " ").map(String.init)
        // 只认普通英文句子，JSON、代码、网址这类带符号的不算。
        guard !line.contains("\n"), (2...25).contains(words.count), !".。".contains(line.last ?? " "),
              line.first?.isLetter == true, !line.contains(where: { "{}[]<>=/\\\"|_@#$%^*".contains($0) }),
              line.filter({ $0.isLetter }).allSatisfy(\.isASCII) else { return nil }
        let shouting = line == line.uppercased()
        let titled = words.enumerated().map { index, original -> String in
            let word = shouting ? original.lowercased() : original
            if word.dropFirst().contains(where: \.isUppercase) { return word }
            let bare = word.lowercased().trimmingCharacters(in: .punctuationCharacters)
            if index > 0, index < words.count - 1, minorWords.contains(bare) { return word.lowercased() }
            return word.split(separator: "-", omittingEmptySubsequences: false).map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: "-")
        }.joined(separator: " ")
        return titled == line ? nil : titled
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
    var isCJK: Bool { unicodeScalars.first.map { (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) } ?? false }
}
