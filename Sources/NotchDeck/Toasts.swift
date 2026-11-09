import SwiftUI

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
