import AppKit

/// 复制内容带的格式：网页、Word、备忘录等会同时放 HTML 和 RTF。
struct RichText: Equatable {
    var rtf: Data?
    var html: Data?

    var byteCount: Int { (rtf?.count ?? 0) + (html?.count ?? 0) }
    var isEmpty: Bool { rtf == nil && html == nil }
}

/// “干净格式”：只保留结构（粗体、斜体、下划线、删除线、链接、列表、标题、引用、代码、表格、上下标），
/// 去掉字体、字号、颜色、背景、class 和 style。输出不带样式的 HTML，粘贴后会套用目标文档自己的默认样式。
enum RichTextCleaner {
    /// 保留的标签，以及统一成的写法。
    private static let kept: [String: String] = [
        "p": "p", "div": "div", "br": "br",
        "b": "b", "strong": "b", "i": "i", "em": "i", "u": "u", "s": "s", "strike": "s", "del": "s",
        "a": "a", "ul": "ul", "ol": "ol", "li": "li",
        "h1": "h1", "h2": "h2", "h3": "h3", "h4": "h4", "h5": "h5", "h6": "h6",
        "blockquote": "blockquote", "pre": "pre", "code": "code",
        "table": "table", "thead": "thead", "tbody": "tbody", "tfoot": "tfoot", "tr": "tr", "td": "td", "th": "th",
        "sup": "sup", "sub": "sub",
    ]
    /// 这些标签连同里面的内容一起去掉。
    private static let dropped: Set<String> = [
        "head", "script", "style", "meta", "link", "title", "noscript", "template", "svg", "math", "img", "picture",
        "video", "audio", "iframe", "object", "embed", "button", "input", "select", "textarea", "form",
    ]
    private static let header = #"<meta charset="utf-8">"#
    /// 这些标签之间的空白只是排版用的换行和缩进，没有意义。
    private static let structural: Set<String> = ["table", "thead", "tbody", "tfoot", "tr", "ul", "ol"]

    /// 有 HTML 就整理 HTML（能保留表格），否则从 RTF 生成。都没有时返回 nil。
    static func cleanHTML(from rich: RichText) -> String? {
        if let html = rich.html, let cleaned = cleanHTML(fromHTML: html) { return cleaned }
        if let rtf = rich.rtf, let attributed = NSAttributedString(rtf: rtf, documentAttributes: nil) {
            return header + html(from: attributed)
        }
        return nil
    }

    // MARK: - HTML

    static func cleanHTML(fromHTML data: Data) -> String? {
        guard let document = try? XMLDocument(data: data, options: [.documentTidyHTML]),
              let root = document.rootElement() else { return nil }
        let body = root.elements(forName: "body").first ?? root
        let content = (body.children ?? []).map { render($0, parent: "body", inPre: false) }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        return content.isEmpty ? nil : header + content
    }

    private static func render(_ node: XMLNode, parent: String, inPre: Bool) -> String {
        switch node.kind {
        case .text:
            let text = node.stringValue ?? ""
            if inPre { return escape(text) }
            if structural.contains(parent), text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "" }
            // 网页里连续的空白和换行只显示成一个空格。
            return escape(text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression))
        case .element:
            guard let element = node as? XMLElement, let name = element.name?.lowercased() else { return "" }
            if dropped.contains(name) { return "" }
            let inner = (element.children ?? []).map { render($0, parent: name, inPre: inPre || name == "pre") }.joined()
            guard let tag = kept[name] else { return inner }   // span、font 等只留里面的内容
            if tag == "br" { return "<br>" }
            var attributes = ""
            if tag == "a" {
                // 没有链接或链接不安全（比如 javascript:）时只留文字。
                guard let href = element.attribute(forName: "href")?.stringValue, isSafeLink(href) else { return inner }
                attributes = #" href="\#(escape(href))""#
            }
            if tag == "td" || tag == "th" {
                for key in ["colspan", "rowspan"] {
                    if let value = element.attribute(forName: key)?.stringValue, Int(value) != nil { attributes += #" \#(key)="\#(value)""# }
                }
            }
            return "<\(tag)\(attributes)>\(inner)</\(tag)>"
        default:
            return ""
        }
    }

    private static func isSafeLink(_ href: String) -> Bool {
        let lower = href.lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("mailto:")
    }

    // MARK: - RTF

    /// 按段落生成 HTML：段落里按字体特征标出粗体、斜体等，带列表样式的段落放进列表。
    static func html(from attributed: NSAttributedString) -> String {
        let text = attributed.string as NSString
        var output = ""
        var openList: String?
        var location = 0
        while location < text.length {
            let paragraph = text.paragraphRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(paragraph)
            var range = paragraph
            // 去掉段尾的换行。
            while range.length > 0, let scalar = UnicodeScalar(text.character(at: NSMaxRange(range) - 1)),
                  CharacterSet.newlines.contains(scalar) { range.length -= 1 }
            let style = range.length > 0 ? attributed.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle : nil
            let list = style?.textLists.last
            let listTag = list.map { $0.markerFormat.rawValue.contains("decimal") || $0.markerFormat.rawValue.contains("alpha") || $0.markerFormat.rawValue.contains("roman") ? "ol" : "ul" }
            if openList != listTag {
                if let openList { output += "</\(openList)>" }
                if let listTag { output += "<\(listTag)>" }
                openList = listTag
            }
            var content = runs(in: attributed, range: range)
            if listTag != nil {
                // RTF 里的列表项文字前面带着项目符号和制表符，HTML 列表会自己加，去掉。
                content = content.replacingOccurrences(of: #"^\t?([•◦▪‣–\-]|\d+[.)]|[a-zA-Z][.)])\t"#, with: "", options: .regularExpression)
                output += "<li>\(content)</li>"
            } else {
                output += content.isEmpty ? "<br>" : "<p>\(content)</p>"
            }
        }
        if let openList { output += "</\(openList)>" }
        return output
    }

    private static func runs(in attributed: NSAttributedString, range: NSRange) -> String {
        guard range.length > 0 else { return "" }
        var output = ""
        attributed.enumerateAttributes(in: range) { attributes, runRange, _ in
            var piece = escape(attributed.attributedSubstring(from: runRange).string)
            guard !piece.isEmpty else { return }
            let traits = (attributes[.font] as? NSFont)?.fontDescriptor.symbolicTraits ?? []
            if traits.contains(.bold) { piece = "<b>\(piece)</b>" }
            if traits.contains(.italic) { piece = "<i>\(piece)</i>" }
            if let underline = attributes[.underlineStyle] as? Int, underline != 0, attributes[.link] == nil { piece = "<u>\(piece)</u>" }
            if let strike = attributes[.strikethroughStyle] as? Int, strike != 0 { piece = "<s>\(piece)</s>" }
            if let offset = attributes[.superscript] as? Int, offset != 0 { piece = offset > 0 ? "<sup>\(piece)</sup>" : "<sub>\(piece)</sub>" }
            let link = (attributes[.link] as? URL)?.absoluteString ?? attributes[.link] as? String
            if let link, isSafeLink(link) { piece = #"<a href="\#(escape(link))">\#(piece)</a>"# }
            output += piece
        }
        return output
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
