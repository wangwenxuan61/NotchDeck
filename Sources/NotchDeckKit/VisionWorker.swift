import CoreGraphics
import Foundation

/// 识别图片文字和抠出主体放在一个临时子进程里做。系统的识别模型一旦加载就会一直留在进程里，
/// 一个文字识别模型就有约 30 MB；子进程做完就退出，这部分内存随之释放。
/// 子进程就是 NotchDeck 自己，带上下面的参数启动时只做识别，不打开界面。
enum VisionWorker {
    static let textFlag = "--recognize-text"
    static let subjectFlag = "--lift-subject"
    /// 子进程超过这个时间还没结束就停掉，按识别失败处理。
    private static let timeout: TimeInterval = 60

    /// 程序入口最先调用。带识别参数启动时做完就退出，否则直接返回。
    static func runIfRequested(_ arguments: [String] = CommandLine.arguments) {
        if let index = arguments.firstIndex(of: textFlag) {
            // 后面每个参数是一张图片文件，按顺序输出识别结果（JSON 字符串数组），识别不出的是空字符串。
            let results = arguments[(index + 1)...].map { path in
                autoreleasepool { image(at: path).flatMap(ClipboardStore.recognizeText) ?? "" }
            }
            FileHandle.standardOutput.write((try? JSONEncoder().encode(Array(results))) ?? Data("[]".utf8))
            exit(0)
        }
        if let index = arguments.firstIndex(of: subjectFlag), arguments.count > index + 2 {
            let png = image(at: arguments[index + 1]).flatMap(ClipboardStore.liftSubject)
            let saved = png.map { (try? $0.write(to: URL(fileURLWithPath: arguments[index + 2]))) != nil } ?? false
            exit(saved ? 0 : 1)
        }
    }

    private static func image(at path: String) -> CGImage? {
        (try? Data(contentsOf: URL(fileURLWithPath: path))).flatMap(ClipboardStore.fullImage)
    }

    /// 只有作为 .app 运行时才用子进程。检查程序和直接运行编译产物时没有可用的子进程入口，就在本进程里做。
    private static var helper: URL? {
        Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main.executableURL : nil
    }

    /// 识别几张图片里的文字，结果和传入的顺序一致。会阻塞调用的线程，不要在主线程调用。
    static func recognizeText(in images: [Data]) -> [String] {
        guard !images.isEmpty else { return [] }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("notchdeck-ocr-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let files: [URL]? = {
            guard helper != nil, (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else { return nil }
            let urls = images.indices.map { folder.appendingPathComponent("\($0)") }
            for (data, url) in zip(images, urls) where (try? data.write(to: url)) == nil { return nil }
            return urls
        }()
        if let files {
            return recognizeText(atPaths: files.map(\.path))
        }
        return images.map { data in ClipboardStore.fullImage(data).flatMap(ClipboardStore.recognizeText) ?? "" }
    }

    /// 识别已经存成文件的图片，比如框选识字的截图。
    static func recognizeText(atPaths paths: [String]) -> [String] {
        if let output = run([textFlag] + paths), let results = try? JSONDecoder().decode([String].self, from: output),
           results.count == paths.count {
            return results
        }
        return paths.map { image(at: $0).flatMap(ClipboardStore.recognizeText) ?? "" }
    }

    /// 抠出图片里的主体，返回透明背景的 PNG。
    static func liftSubject(in image: Data) -> Data? {
        guard helper != nil else { return ClipboardStore.fullImage(image).flatMap(ClipboardStore.liftSubject) }
        let input = FileManager.default.temporaryDirectory.appendingPathComponent("notchdeck-subject-\(UUID().uuidString)")
        let output = input.appendingPathExtension("png")
        defer {
            try? FileManager.default.removeItem(at: input)
            try? FileManager.default.removeItem(at: output)
        }
        guard (try? image.write(to: input)) != nil, run([subjectFlag, input.path, output.path]) != nil else { return nil }
        return try? Data(contentsOf: output)
    }

    /// 启动子进程并等它结束，返回它的输出；没能运行或失败时返回 nil。
    private static func run(_ arguments: [String]) -> Data? {
        guard let helper else { return nil }
        let process = Process()
        process.executableURL = helper
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        return process.terminationReason == .exit && process.terminationStatus == 0 ? output : nil
    }
}
