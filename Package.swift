// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NotchDeck",
    platforms: [.macOS(.v14)],
    targets: [
        // App 的全部代码。
        .target(name: "NotchDeckKit", path: "Sources/NotchDeckKit"),
        // 启动程序，只负责调用 NotchDeckKit。
        .executableTarget(name: "NotchDeck", dependencies: ["NotchDeckKit"], path: "Sources/NotchDeck"),
        // 逻辑检查，不依赖 XCTest，只装命令行工具也能运行：swift run NotchDeckChecks
        .executableTarget(name: "NotchDeckChecks", dependencies: ["NotchDeckKit"], path: "Checks"),
    ]
)
