import SwiftUI

struct PopBarItem: Identifiable {
    let id: String
    let glyph: Glyph
    var tint: Color = Palette.textBright
    var isActive = false
    var isEnabled = true
    var swatch: Color?
    let action: () -> Void
    var onHold: ((CGRect) -> Void)?
    var onTapAt: ((CGRect) -> Void)?
}

struct PopBar: View {
    let groups: [[PopBarItem]]

    private enum Entry: Identifiable {
        case item(PopBarItem)
        case separator(String)

        var id: String {
            switch self {
            case .item(let item): return item.id
            case .separator(let id): return id
            }
        }
    }

    private var entries: [Entry] {
        var entries: [Entry] = []
        for (index, group) in groups.enumerated() where !group.isEmpty {
            if !entries.isEmpty {
                entries.append(.separator("separator-\(index)-\(group[0].id)"))
            }
            entries.append(contentsOf: group.map(Entry.item))
        }
        return entries
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(entries) { entry in
                switch entry {
                case .item(let item):
                    PopBarButton(item: item)
                        .transition(.pop)
                case .separator:
                    Rectangle()
                        .fill(Palette.borderStrong)
                        .frame(width: 1, height: 24)
                        .padding(.horizontal, 4)
                        .transition(.pop)
                }
            }
        }
        .padding(5)
        .background(Capsule().fill(Palette.panelSolid))
        .overlay(Capsule().stroke(Palette.border, lineWidth: 1))
        .animation(Motion.powerThreeInOut(Motion.stateMilliseconds * 2), value: entries.map(\.id))
    }
}

private struct PopBarButton: View {
    let item: PopBarItem

    var body: some View {
        HoldableButton(action: item.action, onHold: item.onHold, onTapAt: item.onTapAt) {
            ZStack {
                Capsule()
                    .fill(Palette.pressedWash)
                    .opacity(item.isActive ? 1 : 0)
                    .scaleEffect(item.isActive ? 1 : 0.6)
                GlyphView(glyph: item.glyph, color: item.isActive ? item.tint : Palette.textBody)
                    .scaleEffect(item.isActive ? 1.06 : 1)
                if let swatch = item.swatch {
                    Circle()
                        .fill(swatch)
                        .frame(width: 6, height: 6)
                        .offset(y: 16)
                }
            }
            .frame(width: 56, height: 48)
            .animation(Motion.backOut(Motion.stateMilliseconds), value: item.isActive)
        }
        .disabled(!item.isEnabled)
        .opacity(item.isEnabled ? 1 : 0.38)
    }
}
