import SwiftUI

struct Card<Content: View>: View {
    var padding: CGFloat = 10
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).cardFill())
    }
}

struct PageHeader<Trailing: View>: View {
    let title: String
    let model: PanelModel
    var backTo: Page = .home
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 6) {
            Button { model.page = backTo } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                    Text(title)
                }
                .font(.system(size: 13, weight: .semibold))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer()
            trailing
        }
        .frame(height: 20)
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: String, model: PanelModel) {
        self.init(title: title, model: model) { EmptyView() }
    }
}

struct PillButton: View {
    let title: String
    var symbol: String?
    var prominent = false
    var width: CGFloat?
    var horizontalPadding: CGFloat = 10
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol) }
                Text(title).lineLimit(1).minimumScaleFactor(0.7)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(prominent ? Color.white : Theme.primary)
            .padding(.horizontal, horizontalPadding)
            .frame(width: width, height: 26)
            .capsuleFill(prominent ? Theme.blue : Theme.control)
        }
        .buttonStyle(.plain)
    }
}

struct IconButton: View {
    let symbol: String
    var selected = false
    var help = ""
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(selected ? Theme.blue : Theme.primary)
                .frame(width: 28, height: 28)
                .background(Circle().fill(selected ? Theme.blue.opacity(0.16) : (hovering ? Theme.controlHover : Theme.control)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
    }
}
