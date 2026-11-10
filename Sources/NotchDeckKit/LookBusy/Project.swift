import Foundation

enum Lang: String {
    case typescript, python, swift, go, cpp

    static func from(ext: String) -> Lang? {
        switch ext.lowercased() {
        case "ts", "tsx", "js", "jsx", "mjs": return .typescript
        case "py": return .python
        case "swift": return .swift
        case "go": return .go
        case "cpp", "cc", "cxx", "cu", "c", "h", "hpp": return .cpp
        default: return nil
        }
    }

    var display: String {
        switch self {
        case .typescript: return "TypeScript"
        case .python: return "Python"
        case .swift: return "Swift"
        case .go: return "Go"
        case .cpp: return "C++"
        }
    }
}

/// Only file and folder names are read from a project; file contents are never opened.
struct Project {
    let name: String
    let files: [String]      // relative paths shown in the explorer
    let lang: Lang
    let editable: [String]   // files of the dominant language, the ones that get "edited"

    static let skipped: Set<String> = [
        "node_modules", ".git", "build", "dist", ".build", "target", "venv", ".venv", "__pycache__",
        "DerivedData", "Pods", ".next", "out", "coverage", "third_party", "vendor", ".idea", ".vscode",
    ]

    static func scan(_ root: URL) -> Project {
        let fm = FileManager.default
        var files: [String] = []
        let prefix = root.standardizedFileURL.path + "/"
        if let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                 options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            for case let url as URL in e {
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDir {
                    if skipped.contains(url.lastPathComponent) || e.level > 5 { e.skipDescendants() }
                    continue
                }
                let path = url.standardizedFileURL.path
                guard path.hasPrefix(prefix) else { continue }
                files.append(String(path.dropFirst(prefix.count)))
                if files.count >= 600 { break }
            }
        }
        var counts: [Lang: Int] = [:]
        for f in files { if let l = Lang.from(ext: (f as NSString).pathExtension) { counts[l, default: 0] += 1 } }
        guard let lang = counts.max(by: { $0.value < $1.value })?.key else {
            return Project(name: root.lastPathComponent, files: demo.files, lang: demo.lang, editable: demo.editable)
        }
        let code = files.filter {
            Lang.from(ext: ($0 as NSString).pathExtension) == lang && !$0.lowercased().contains("test")
        }
        // Prefer real source folders over docs, examples and scripts.
        let aside = ["docs/", "doc/", "examples/", "example/", "scripts/", "notebooks/"]
        let core = code.filter { f in !aside.contains { f.lowercased().hasPrefix($0) } }
        let editable = core.count >= 3 ? core : code
        return Project(name: root.lastPathComponent, files: files.sorted(), lang: lang,
                       editable: editable.isEmpty ? files.filter { Lang.from(ext: ($0 as NSString).pathExtension) == lang } : editable)
    }

    static let demo: Project = {
        let files = [
            "package.json", "tsconfig.json", "README.md", ".env.example",
            "src/index.ts", "src/server.ts",
            "src/auth/session.ts", "src/auth/tokens.ts", "src/auth/oauth-callback.ts",
            "src/billing/invoice-queue.ts", "src/billing/ledger.ts", "src/billing/stripe-webhook.ts",
            "src/cache/redis-client.ts", "src/cache/rate-limiter.ts",
            "src/db/schema.ts", "src/db/migrations/2026_10_add_ledger.ts",
            "src/lib/retry.ts", "src/lib/logger.ts", "src/lib/feature-flags.ts",
            "src/routes/users.ts", "src/routes/billing.ts", "src/routes/health.ts",
            "src/workers/email-digest.ts", "src/workers/usage-rollup.ts",
            "test/auth/session.test.ts", "test/billing/ledger.test.ts", "test/lib/retry.test.ts",
        ]
        let editable = files.filter { $0.hasPrefix("src/") && $0.hasSuffix(".ts") && !$0.hasSuffix("index.ts") }
        return Project(name: "orbit-api", files: files, lang: .typescript, editable: editable)
    }()
}
