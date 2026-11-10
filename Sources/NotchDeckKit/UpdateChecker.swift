import AppKit

/// 向 GitHub 查询最新发布的版本号，只读取版本信息，不上传任何使用数据。
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    private static let latestReleaseAPI = URL(string: "https://api.github.com/repos/wangwenxuan61/NotchDeck/releases/latest")!
    private static let downloadPage = URL(string: "https://github.com/wangwenxuan61/NotchDeck/releases/latest")!
    private static let checkInterval: TimeInterval = 86_400
    private static let autoCheckKey = "checkForUpdates"
    private static let notifiedVersionKey = "lastNotifiedUpdate"

    private struct Release: Decodable {
        let tagName: String
        enum CodingKeys: String, CodingKey { case tagName = "tag_name" }
    }

    let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

    /// 有比当前更新的版本时才有值。
    @Published private(set) var latestVersion: String?
    @Published private(set) var isChecking = false
    @Published var autoCheck: Bool {
        didSet {
            UserDefaults.standard.set(autoCheck, forKey: Self.autoCheckKey)
            if autoCheck { check(userInitiated: false) }
        }
    }

    private var lastCheck = Date.distantPast
    private var timer: Timer?

    private init() {
        autoCheck = UserDefaults.standard.object(forKey: Self.autoCheckKey) as? Bool ?? true
    }

    func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.checkIfDue() }
        let timer = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in self?.checkIfDue() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func checkIfDue() {
        guard autoCheck, Date().timeIntervalSince(lastCheck) >= Self.checkInterval else { return }
        check(userInitiated: false)
    }

    func check(userInitiated: Bool) {
        guard !isChecking else { return }
        isChecking = true
        var request = URLRequest(url: Self.latestReleaseAPI, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            let succeeded = (response as? HTTPURLResponse)?.statusCode == 200
            let tag = succeeded ? data.flatMap { try? JSONDecoder().decode(Release.self, from: $0) }?.tagName : nil
            DispatchQueue.main.async { self?.finish(tag: tag, userInitiated: userInitiated) }
        }.resume()
    }

    private func finish(tag: String?, userInitiated: Bool) {
        isChecking = false
        guard let tag else {
            // 自动检查失败时不打扰用户。lastCheck 不更新，一小时后的定时器会再试。
            if userInitiated { Toasts.shared.show(L("检查更新失败"), icon: "exclamationmark.triangle") }
            return
        }
        lastCheck = Date()
        guard let version = Self.newerVersion(tag: tag, than: currentVersion) else {
            latestVersion = nil
            if userInitiated { Toasts.shared.show(L("已是最新版本"), icon: "checkmark.circle") }
            return
        }
        latestVersion = version
        let defaults = UserDefaults.standard
        if userInitiated || defaults.string(forKey: Self.notifiedVersionKey) != version {
            defaults.set(version, forKey: Self.notifiedVersionKey)
            Toasts.shared.show(L("发现新版本 %@", version), icon: "arrow.up.circle")
        }
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
