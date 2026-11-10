import AppKit
import CryptoKit
import Security

/// 下载新版本的 DMG，校验后替换正在运行的 NotchDeck.app 并重新打开。
/// 每一步出错都会抛出，调用方退回到打开下载页面，原来的 App 不受影响。
enum UpdateInstaller {
    struct Asset: Equatable {
        let url: URL
        /// GitHub 给每个附件算的 SHA-256，旧的发布可能没有。
        let sha256: String?
    }

    enum Failure: Error, Equatable {
        case noAsset, download, checksum, mount, missingApp, wrongApp, signature, wrongSigner, notWritable, replace
    }

    private static let appName = "NotchDeck.app"

    // MARK: - 选附件

    /// 从 GitHub 发布信息里找 DMG：优先 Apple 芯片版本。
    static func dmgAsset(in release: [String: Any]) -> Asset? {
        let assets = (release["assets"] as? [[String: Any]] ?? []).filter { ($0["name"] as? String)?.hasSuffix(".dmg") == true }
        let preferred = assets.first { ($0["name"] as? String)?.contains("arm64") == true } ?? assets.first
        guard let asset = preferred, let link = asset["browser_download_url"] as? String,
              let url = URL(string: link), url.scheme == "https" else { return nil }
        var digest = asset["digest"] as? String
        if let value = digest, value.hasPrefix("sha256:") { digest = String(value.dropFirst(7)).lowercased() } else { digest = nil }
        return Asset(url: url, sha256: digest)
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 准备新版本

    /// 下载并校验 DMG，把里面的 App 复制到 currentApp 旁边的临时位置，返回这个位置。
    /// 放在同一个文件夹里，替换时只是改名，不会出现复制到一半的 App。
    static func prepare(asset: Asset, version: String, replacing currentApp: URL, bundleID: String) throws -> URL {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("NotchDeckUpdate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let dmg = work.appendingPathComponent("update.dmg")
        try download(asset.url, to: dmg)
        if let expected = asset.sha256, try sha256(of: dmg) != expected { throw Failure.checksum }

        let folder = currentApp.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: folder.path) else { throw Failure.notWritable }
        let requirement = signingRequirement(of: currentApp)
        let staged = folder.appendingPathComponent(".NotchDeck-update-\(UUID().uuidString).app")
        do {
            try copyApp(fromDMG: dmg, mountPoint: work.appendingPathComponent("mount"), to: staged)
            try validate(app: staged, bundleID: bundleID, version: version, requirement: requirement)
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
        return staged
    }

    private static func download(_ url: URL, to destination: URL) throws {
        let done = DispatchSemaphore(value: 0)
        var failure: Error?
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        URLSession.shared.downloadTask(with: request) { location, response, error in
            defer { done.signal() }
            guard error == nil, let location, (response as? HTTPURLResponse)?.statusCode == 200 else {
                failure = Failure.download
                return
            }
            // 下载的临时文件在回调结束后就会被删掉，要先移走。
            do { try FileManager.default.moveItem(at: location, to: destination) } catch { failure = Failure.download }
        }.resume()
        done.wait()
        if let failure { throw failure }
    }

    /// 只读挂载 DMG，用 ditto 原样复制 App（保留签名），然后卸载。
    static func copyApp(fromDMG dmg: URL, mountPoint: URL, to destination: URL) throws {
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        guard run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-noverify", "-mountpoint", mountPoint.path]) else {
            throw Failure.mount
        }
        defer { _ = run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force"]) }
        let app = mountPoint.appendingPathComponent(appName)
        guard FileManager.default.fileExists(atPath: app.path) else { throw Failure.missingApp }
        guard run("/usr/bin/ditto", [app.path, destination.path]) else { throw Failure.missingApp }
        // 自己下载的文件本来就没有隔离标记，这里再确认一次，免得新版本第一次打开被拦下。
        _ = run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", destination.path])
    }

    /// 必须是同一个 App、正好是要更新的版本，并且签名完整。
    /// 给了 requirement 时，新版本还必须满足它，也就是和当前版本用同一个证书签名。
    static func validate(app: URL, bundleID: String, version: String, requirement: SecRequirement? = nil) throws {
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any],
              info["CFBundleIdentifier"] as? String == bundleID,
              info["CFBundleShortVersionString"] as? String == version else { throw Failure.wrongApp }
        guard run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]) else { throw Failure.signature }
        if let requirement {
            var code: SecStaticCode?
            guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
                  SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode), requirement) == errSecSuccess
            else { throw Failure.wrongSigner }
        }
    }

    /// 当前 App 的签名要求，只在它是用证书签名时返回。临时签名的要求是这一个版本的哈希值，
    /// 每个版本都不同，不能拿来要求新版本，所以返回 nil，从临时签名的版本也能更新到证书签名的版本。
    static func signingRequirement(of app: URL) -> SecRequirement? {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        var text: CFString?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess, let requirement,
              SecRequirementCopyString(requirement, [], &text) == errSecSuccess,
              (text as String?)?.contains("certificate") == true else { return nil }
        return requirement
    }

    // MARK: - 替换并重新打开

    /// 先把旧版本改名挪开，再把新版本改名放到原位置；第二步失败就把旧版本放回去。
    static func replace(_ currentApp: URL, with staged: URL) throws {
        let folder = currentApp.deletingLastPathComponent()
        let old = folder.appendingPathComponent(".NotchDeck-old-\(UUID().uuidString).app")
        let manager = FileManager.default
        do {
            try manager.moveItem(at: currentApp, to: old)
        } catch {
            try? manager.removeItem(at: staged)
            throw Failure.replace
        }
        do {
            try manager.moveItem(at: staged, to: currentApp)
        } catch {
            try? manager.moveItem(at: old, to: currentApp)
            try? manager.removeItem(at: staged)
            throw Failure.replace
        }
        try? manager.removeItem(at: old)
    }

    /// 等当前进程退出后再打开新版本。
    static func relaunch(_ app: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\"",
                             app.path, String(ProcessInfo.processInfo.processIdentifier)]
        try? process.run()
        NSApp.terminate(nil)
    }

    /// 上次没装完留下的新版本，或者没删掉的旧版本。
    static func removeLeftovers(next app: URL) {
        let folder = app.deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where name.hasSuffix(".app") && (name.hasPrefix(".NotchDeck-update-") || name.hasPrefix(".NotchDeck-old-")) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
