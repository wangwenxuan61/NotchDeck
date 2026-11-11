import AppKit

/// 向 GitHub 查询最新发布的版本，只读取发布信息，不上传任何使用数据。
/// 开启自动更新时，发现新版本就在后台下载并校验，等用户没在用 NotchDeck 时替换并重新打开；
/// 出了问题就退回到打开下载页面。
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    private static let latestReleaseAPI = URL(string: "https://api.github.com/repos/wangwenxuan61/NotchDeck/releases/latest")!
    private static let downloadPage = URL(string: "https://github.com/wangwenxuan61/NotchDeck/releases/latest")!
    private static let checkInterval: TimeInterval = 6 * 3600
    private static let autoCheckKey = "checkForUpdates"
    private static let notifiedVersionKey = "lastNotifiedUpdate"
    private static let updatedFromKey = "updatedFromVersion"

    enum Phase: Equatable {
        case idle, downloading, ready, failed
    }

    let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

    /// 有比当前更新的版本时才有值。
    @Published private(set) var latestVersion: String?
    @Published private(set) var isChecking = false
    @Published private(set) var phase = Phase.idle
    /// 开启后自动下载并安装新版本，键名沿用原来的“自动检查更新”。
    @Published var autoCheck: Bool {
        didSet {
            UserDefaults.standard.set(autoCheck, forKey: Self.autoCheckKey)
            if autoCheck { check(userInitiated: false) }
        }
    }

    private var lastCheck = Date.distantPast
    private var timer: Timer?
    private var asset: UpdateInstaller.Asset?
    /// 已经下载、校验好的新版本，放在当前 App 旁边。
    private var staged: URL?
    /// 连续几次检查都没在用，才自动安装。
    private var quietChecks = 0
    /// 更新后第一次打开面板时提示一下。
    private var updateNotice: String?
    /// 用户点了“更新到”，这次检查完就下载并立即安装。
    private var installAfterCheck = false

    private init() {
        autoCheck = UserDefaults.standard.object(forKey: Self.autoCheckKey) as? Bool ?? true
        let defaults = UserDefaults.standard
        if let previous = defaults.string(forKey: Self.updatedFromKey) {
            defaults.removeObject(forKey: Self.updatedFromKey)
            if previous != currentVersion { updateNotice = currentVersion }
        }
    }

    func start() {
        UpdateInstaller.removeLeftovers(next: Bundle.main.bundleURL)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.checkIfDue() }
        // 每分钟看一次：到时间就检查新版本，有下载好的新版本就看能不能安装。
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// 更新后第一次打开面板时调用：这个版本写了新功能就打开新功能页，否则提示一下版本号。
    /// 用快捷键直接打开某一页（比如剪贴板）时先不打扰，留到下次从首页打开。
    func showUpdateNoticeIfNeeded(in model: PanelModel) {
        guard let version = updateNotice else { return }
        guard ReleaseNotes.notes(for: version) != nil else {
            updateNotice = nil
            Toasts.shared.show(L("已更新到 %@", version), icon: "checkmark.seal")
            return
        }
        guard model.page == .home else { return }
        updateNotice = nil
        model.whatsNewReturn = .home
        model.page = .whatsNew
    }

    private func tick() {
        checkIfDue()
        guard autoCheck, phase == .ready else { return }
        quietChecks = isQuiet ? quietChecks + 1 : 0
        if quietChecks >= 2 { install() }
    }

    private func checkIfDue() {
        guard autoCheck, Date().timeIntervalSince(lastCheck) >= Self.checkInterval else { return }
        check(userInitiated: false)
    }

    /// 面板关着、没有在计时、没在装忙，这时重启不会打断任何事。防止休眠会在新版本里恢复，不用等它关掉。
    private var isQuiet: Bool {
        let app = AppDelegate.shared
        return !app.controller.model.expanded && !app.modalOpen && !LookBusyController.shared.isShowing
            && !CountdownTimer.shared.isActive && !FocusTimer.shared.running && !Stopwatch.shared.isRunning
    }

    func check(userInitiated: Bool) {
        guard !isChecking else { return }
        isChecking = true
        var request = URLRequest(url: Self.latestReleaseAPI, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            let succeeded = (response as? HTTPURLResponse)?.statusCode == 200
            let release = succeeded ? data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } : nil
            DispatchQueue.main.async { self?.finish(release: release, userInitiated: userInitiated) }
        }.resume()
    }

    private func finish(release: [String: Any]?, userInitiated: Bool) {
        isChecking = false
        let wantsInstall = installAfterCheck
        installAfterCheck = false
        guard let tag = release?["tag_name"] as? String else {
            // 自动检查失败时不打扰用户，半小时后再试。
            lastCheck = Date().addingTimeInterval(30 * 60 - Self.checkInterval)
            if wantsInstall {
                fail(userInitiated: true)
            } else if userInitiated {
                Toasts.shared.show(L("检查更新失败"), icon: "exclamationmark.triangle")
            }
            return
        }
        lastCheck = Date()
        guard let version = Self.newerVersion(tag: tag, than: currentVersion) else {
            latestVersion = nil
            if userInitiated { Toasts.shared.show(L("已是最新版本"), icon: "checkmark.circle") }
            return
        }
        if version != latestVersion {
            // 又有了更新的版本，之前下载好的作废。
            discardStaged()
            phase = .idle
        }
        latestVersion = version
        asset = release.flatMap(UpdateInstaller.dmgAsset)
        if wantsInstall {
            if phase == .ready { install() } else { download(thenInstall: true) }
            return
        }
        if autoCheck {
            // 上次下载失败的，下次检查时再试一次。
            if phase == .idle || phase == .failed { download(thenInstall: false) }
            return
        }
        let defaults = UserDefaults.standard
        if userInitiated || defaults.string(forKey: Self.notifiedVersionKey) != version {
            defaults.set(version, forKey: Self.notifiedVersionKey)
            Toasts.shared.show(L("发现新版本 %@", version), icon: "arrow.up.circle")
        }
    }

    /// 设置页和右键菜单里的“更新到”：已经下载好就立即安装；否则先重新获取发布信息，再马上下载并安装。
    /// 重新获取是为了用最新的下载地址和校验值，之前自动下载失败过也会重新试，这次也失败才打开下载页面。
    func updateNow() {
        switch phase {
        case .ready: install()
        case .downloading: break
        case .failed, .idle:
            installAfterCheck = true
            check(userInitiated: true)
        }
    }

    private func download(thenInstall: Bool) {
        guard let version = latestVersion, let asset, let bundleID = Bundle.main.bundleIdentifier else {
            if thenInstall { openDownloadPage() }
            return
        }
        phase = .downloading
        let current = Bundle.main.bundleURL
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result { try UpdateInstaller.prepare(asset: asset, version: version, replacing: current, bundleID: bundleID) }
            DispatchQueue.main.async {
                guard let self, self.latestVersion == version else {
                    if case .success(let url) = result { try? FileManager.default.removeItem(at: url) }
                    return
                }
                switch result {
                case .success(let url):
                    self.staged = url
                    self.phase = .ready
                    self.quietChecks = 0
                    if thenInstall { self.install() }
                case .failure:
                    self.fail(userInitiated: thenInstall)
                }
            }
        }
    }

    private func install() {
        // 下载好的新版本被删掉了（比如手动清理），重新下载。
        guard let staged, FileManager.default.fileExists(atPath: staged.path) else {
            self.staged = nil
            download(thenInstall: true)
            return
        }
        self.staged = nil
        let current = Bundle.main.bundleURL
        do {
            try UpdateInstaller.replace(current, with: staged)
        } catch {
            fail(userInitiated: true)
            return
        }
        UserDefaults.standard.set(currentVersion, forKey: Self.updatedFromKey)
        ClipboardStore.shared.persistForRestart()
        KeepAwake.shared.saveForRestart()
        UpdateInstaller.relaunch(current)
    }

    /// 自动下载失败时不打扰用户，设置页的按钮会变成打开下载页面；用户点的才提示并打开下载页面。
    private func fail(userInitiated: Bool) {
        phase = .failed
        guard userInitiated else { return }
        Toasts.shared.show(L("自动更新失败，可以手动下载"), icon: "exclamationmark.triangle")
        openDownloadPage()
    }

    private func discardStaged() {
        if let staged { try? FileManager.default.removeItem(at: staged) }
        staged = nil
    }

    /// 发布标签形如 v0.1.5。按数字逐段比较，0.1.10 比 0.1.9 新；不比当前版本新时返回 nil。
    static func newerVersion(tag: String, than current: String) -> String? {
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return version.compare(current, options: .numeric) == .orderedDescending ? version : nil
    }

    func openDownloadPage() {
        AppDelegate.shared.closePanel()
        NSWorkspace.shared.open(Self.downloadPage)
    }
}
