import SwiftUI
import UserNotifications

final class Toasts: ObservableObject {
    static let shared = Toasts()
    struct Toast: Equatable { let text: String; let icon: String }

    @Published private(set) var current: Toast?
    private var clearWork: DispatchWorkItem?

    func show(_ text: String, icon: String) {
        clearWork?.cancel()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { current = Toast(text: text, icon: icon) }
        let work = DispatchWorkItem { [weak self] in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { self?.current = nil }
        }
        clearWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }
}

/// 计时结束时发系统通知，人不在电脑前也能在通知中心看到。第一次开始计时时才申请权限。
final class SystemNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = SystemNotifier()

    /// 没有 Bundle 的进程（比如直接运行编译产物）调用通知接口会崩溃。
    private var center: UNUserNotificationCenter? {
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        return center
    }

    func requestPermission() {
        center?.requestAuthorization(options: [.alert]) { _, _ in }
    }

    /// 提示音已经由 App 自己播放，通知不再带声音。
    func post(_ title: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        center?.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}
