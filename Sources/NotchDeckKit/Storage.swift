import Foundation

enum Storage {
    static let folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("NotchDeck", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func save<T: Encodable>(_ value: T, to name: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: folder.appendingPathComponent(name), options: .atomic)
    }

    /// 偏好设置按 Bundle ID 存放，改 ID 后要把旧设置带过来。必须在任何设置被读取之前调用。
    /// 旧设置文件不删除，退回旧版本时还能用。
    static func migrateLegacySettings() {
        let defaults = UserDefaults.standard
        let migratedKey = "migratedLegacySettings"
        guard !defaults.bool(forKey: migratedKey) else { return }
        for (key, value) in defaults.persistentDomain(forName: "local.notchdeck.app") ?? [:] {
            defaults.set(value, forKey: key)
        }
        defaults.set(true, forKey: migratedKey)
    }
}
