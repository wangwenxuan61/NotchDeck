import AppKit

enum Shell {
    /// 运行命令并等待结束，返回标准输出；启动失败时返回 nil。不要在主线程调用。
    static func output(_ path: String, _ arguments: [String], environment: [String: String]? = nil) -> Data? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        if let environment { process.environment = environment }
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return data
    }

    /// 启动命令后立即返回，不等待结果。
    static func launch(_ path: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        try? process.run()
    }
}

/// 部分系统功能没有公开接口，只能动态调用私有函数；函数不存在时返回 nil，对应功能显示为不可用。
func systemFunction<T>(_ path: String, _ name: String, as type: T.Type) -> T? {
    guard let handle = dlopen(path, RTLD_LAZY), let symbol = dlsym(handle, name) else { return nil }
    return unsafeBitCast(symbol, to: type)
}

func openCalendarApp() {
    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Calendar.app"))
}
