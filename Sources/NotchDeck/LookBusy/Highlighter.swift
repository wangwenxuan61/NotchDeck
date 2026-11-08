import SwiftUI

/// A tiny line-based highlighter: good enough to look like an editor at a glance.
enum Highlighter {
    struct Palette {
        let plain, keyword, control, string, number, comment, type, function, variable: Color

        static let dark = Palette(
            plain: Color(hex: 0xD4D4D4), keyword: Color(hex: 0x569CD6), control: Color(hex: 0xC586C0),
            string: Color(hex: 0xCE9178), number: Color(hex: 0xB5CEA8), comment: Color(hex: 0x6A9955),
            type: Color(hex: 0x4EC9B0), function: Color(hex: 0xDCDCAA), variable: Color(hex: 0x9CDCFE))
        /// Close to JupyterLab's light theme.
        static let light = Palette(
            plain: Color(hex: 0x212121), keyword: Color(hex: 0x008000), control: Color(hex: 0x008000),
            string: Color(hex: 0xBA2121), number: Color(hex: 0x116644), comment: Color(hex: 0x3D7B7B),
            type: Color(hex: 0x0055AA), function: Color(hex: 0x0000FF), variable: Color(hex: 0x212121))
    }

    private static let controlWords: Set<String> = [
        "return", "if", "else", "elif", "for", "while", "switch", "case", "default", "break", "continue",
        "try", "catch", "except", "finally", "throw", "throws", "raise", "await", "async", "guard", "do",
        "import", "from", "export", "select", "go", "defer", "with", "yield", "in", "of", "range",
    ]
    private static let keywords: [Lang: Set<String>] = [
        .typescript: ["const", "let", "var", "function", "class", "extends", "implements", "interface", "type", "as",
                      "new", "private", "readonly", "public", "static", "true", "false", "null", "undefined", "this",
                      "typeof", "void", "constructor"],
        .python: ["def", "class", "None", "True", "False", "lambda", "not", "and", "or", "is", "pass", "self",
                  "global", "nonlocal", "del", "assert"],
        .swift: ["struct", "class", "actor", "enum", "protocol", "extension", "func", "var", "let", "private",
                 "public", "internal", "static", "self", "Self", "nil", "true", "false", "init", "some", "any", "inout"],
        .go: ["package", "func", "type", "struct", "interface", "chan", "map", "var", "const", "nil", "true", "false"],
        .cpp: ["namespace", "class", "struct", "public", "private", "protected", "const", "auto", "static_cast",
               "explicit", "void", "int", "float", "double", "bool", "true", "false", "nullptr", "template",
               "typename", "using", "new", "delete", "std", "size_t"],
    ]

    static func line(_ text: String, lang: Lang, palette p: Palette = .dark) -> AttributedString {
        let plain = p.plain, keyword = p.keyword, control = p.control, string = p.string, number = p.number
        let comment = p.comment, type = p.type, function = p.function, variable = p.variable
        var out = AttributedString()
        let chars = Array(text)
        let kw = keywords[lang] ?? []
        let lineComment: [Character] = lang == .python ? ["#"] : ["/", "/"]
        var i = 0
        func emit(_ s: String, _ c: Color) {
            var a = AttributedString(s)
            a.foregroundColor = c
            out.append(a)
        }
        if lang == .cpp, text.trimmingCharacters(in: .whitespaces).hasPrefix("#") {
            emit(text, control)
            return out
        }
        while i < chars.count {
            let ch = chars[i]
            // comments run to the end of the line
            if ch == lineComment[0], lineComment.count == 1 || (i + 1 < chars.count && chars[i + 1] == lineComment[1]) {
                emit(String(chars[i...]), comment)
                break
            }
            if ch == "\"" || ch == "'" || ch == "`" {
                var j = i + 1
                while j < chars.count && chars[j] != ch { j += chars[j] == "\\" ? 2 : 1 }
                j = min(j + 1, chars.count)
                emit(String(chars[i..<j]), string)
                i = j
                continue
            }
            if ch.isNumber {
                var j = i
                while j < chars.count && (chars[j].isNumber || chars[j] == "." || chars[j] == "_" || chars[j] == "f" || chars[j] == "x") { j += 1 }
                emit(String(chars[i..<j]), number)
                i = j
                continue
            }
            if ch.isLetter || ch == "_" || ch == "$" || ch == "@" {
                var j = i
                while j < chars.count && (chars[j].isLetter || chars[j].isNumber || chars[j] == "_" || chars[j] == "$" || chars[j] == "@") { j += 1 }
                let word = String(chars[i..<j])
                var k = j
                while k < chars.count && chars[k] == " " { k += 1 }
                let isCall = k < chars.count && chars[k] == "("
                let color: Color
                if controlWords.contains(word) { color = control }
                else if kw.contains(word) { color = keyword }
                else if word.hasPrefix("@") { color = function }
                else if isCall { color = function }
                else if word.first?.isUppercase == true { color = type }
                else { color = variable }
                emit(word, color)
                i = j
                continue
            }
            var j = i
            while j < chars.count {
                let c = chars[j]
                if c.isLetter || c.isNumber || c == "_" || c == "\"" || c == "'" || c == "`" || c == "$" || c == "@" { break }
                if c == lineComment[0], lineComment.count == 1 || (j + 1 < chars.count && chars[j + 1] == lineComment[1]) { break }
                j += 1
            }
            if j == i { j = i + 1 }
            emit(String(chars[i..<j]), plain)
            i = j
        }
        return out
    }
}
