import SwiftUI

/// 原始值存在 note.json 里，顺序不能改。
enum NoteColor: Int, CaseIterable {
    case green, yellow, pink, blue

    var title: String {
        switch self {
        case .green: return L("青绿")
        case .yellow: return L("明黄")
        case .pink: return L("粉红")
        case .blue: return L("天蓝")
        }
    }

    var color: Color {
        switch self {
        case .green: return Color(red: 0.76, green: 0.82, blue: 0.66)
        case .yellow: return Color(red: 0.96, green: 0.87, blue: 0.56)
        case .pink: return Color(red: 0.95, green: 0.75, blue: 0.76)
        case .blue: return Color(red: 0.70, green: 0.82, blue: 0.94)
        }
    }
}

final class NoteStore: ObservableObject {
    static let shared = NoteStore()

    private struct Saved: Codable { var text: String; var color: Int }

    @Published var text: String { didSet { scheduleSave() } }
    @Published var colorIndex: Int { didSet { scheduleSave() } }
    private var pendingSave: DispatchWorkItem?

    private init() {
        let saved = Storage.load(Saved.self, from: "note.json")
        text = saved?.text ?? ""
        colorIndex = saved?.color ?? 0
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Storage.save(Saved(text: self.text, color: self.colorIndex), to: "note.json")
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }
}

struct NoteCard: View {
    @ObservedObject private var store = NoteStore.shared

    private var color: Color { (NoteColor(rawValue: store.colorIndex) ?? .green).color }

    var body: some View {
        Card(padding: 8) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Image(systemName: "note.text").foregroundStyle(Theme.orange)
                    Text(L("短记")).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Menu {
                        ForEach(NoteColor.allCases, id: \.self) { option in
                            Button(option.title) { store.colorIndex = option.rawValue }
                        }
                        Divider()
                        Button(L("清空")) { store.text = "" }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
                .padding(.horizontal, 2)

                TextEditor(text: $store.text)
                    .font(.system(size: 12))
                    .scrollContentBackground(.hidden)
                    .scrollIndicators(.never)
                    .foregroundStyle(Color.black.opacity(0.82))
                    .colorScheme(.light)
                    .padding(5)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(color))
            }
        }
    }
}
