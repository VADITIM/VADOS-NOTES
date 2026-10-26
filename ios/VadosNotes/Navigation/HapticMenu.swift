import SwiftUI

struct MenuSlot: Identifiable {
    let position: Int
    let title: String
    let role: MenuRole
    var swatch: String?
    var isEnabled = true
    var isActive = false
    let handler: () -> Void

    var id: Int { position }

    var isDestructive: Bool { role == .destructive }

    var tint: Color {
        if let swatch {
            return Color(hex: swatch)
        }
        return Palette.color(for: role)
    }

    static func fromTokens(_ tokens: [Tokens.MenuSlotToken], title: (String) -> String, isEnabled: (String) -> Bool = { _ in true }, perform: @escaping (String) -> Void) -> [MenuSlot] {
        tokens.map { token in
            MenuSlot(
                position: token.slot,
                title: title(token.action),
                role: MenuRole(rawValue: token.role) ?? .view,
                isEnabled: isEnabled(token.action),
                handler: { perform(token.action) }
            )
        }
    }
}

@MainActor
final class MenuController: ObservableObject {
    struct Presentation {
        let slots: [MenuSlot]
        let columns: Int
        let rows: Int
        let origin: CGPoint
        let title: String?
    }

    static let slotSize = CGSize(width: 132, height: 64)
    static let spacing: CGFloat = 6
    static let padding: CGFloat = 8
    static let titleHeight: CGFloat = 26
    static let screenMargin: CGFloat = 16
    static let fingerClearance: CGFloat = 28

    @Published private(set) var presentation: Presentation?
    @Published private(set) var highlightedPosition: Int?
    @Published private(set) var armedPosition: Int?
    var screenSize: CGSize = CGSize(width: 1024, height: 1366)

    func present(_ slots: [MenuSlot], columns: Int = Tokens.shared.menus.columns, around anchor: CGRect, title: String? = nil) {
        let rows = ((slots.map(\.position).max() ?? 0) / columns) + 1
        let size = Self.panelSize(columns: columns, rows: rows, hasTitle: title != nil)
        var origin = CGPoint(x: anchor.midX - size.width / 2, y: anchor.minY - size.height - Self.spacing * 2)
        if origin.y < Self.screenMargin {
            origin.y = anchor.maxY + Self.spacing * 2
        }
        origin.x = min(max(Self.screenMargin, origin.x), screenSize.width - size.width - Self.screenMargin)
        origin.y = min(max(Self.screenMargin, origin.y), screenSize.height - size.height - Self.screenMargin)
        armedPosition = nil
        highlightedPosition = nil
        withAnimation(Motion.backOut(Motion.overlayEnterMilliseconds)) {
            presentation = Presentation(slots: slots, columns: columns, rows: rows, origin: origin, title: title)
        }
    }

    func present(_ slots: [MenuSlot], columns: Int = Tokens.shared.menus.columns, at point: CGPoint, title: String? = nil) {
        present(slots, columns: columns, around: CGRect(origin: point, size: .zero).insetBy(dx: 0, dy: -Self.fingerClearance), title: title)
    }

    func drag(to point: CGPoint) {
        let position = slotPosition(at: point)
        guard position != highlightedPosition else { return }
        highlightedPosition = position
        if position != nil {
            Haptics.segment()
        }
    }

    func release(at point: CGPoint) {
        highlightedPosition = nil
        if let position = slotPosition(at: point) {
            activate(position)
        }
    }

    func activate(_ position: Int) {
        guard let slot = presentation?.slots.first(where: { $0.position == position }), slot.isEnabled else { return }
        if slot.isDestructive && armedPosition != position {
            armedPosition = position
            Haptics.tick()
            return
        }
        dismiss()
        Haptics.landed()
        slot.handler()
    }

    func dismiss() {
        withAnimation(Motion.powerTwoIn(Motion.overlayLeaveMilliseconds)) {
            presentation = nil
        }
        armedPosition = nil
        highlightedPosition = nil
    }

    static func panelSize(columns: Int, rows: Int, hasTitle: Bool) -> CGSize {
        CGSize(
            width: padding * 2 + CGFloat(columns) * slotSize.width + CGFloat(columns - 1) * spacing,
            height: padding * 2 + CGFloat(rows) * slotSize.height + CGFloat(rows - 1) * spacing + (hasTitle ? titleHeight : 0)
        )
    }

    static func slotOrigin(position: Int, columns: Int, hasTitle: Bool) -> CGPoint {
        let column = position % columns
        let row = position / columns
        return CGPoint(
            x: padding + CGFloat(column) * (slotSize.width + spacing),
            y: padding + (hasTitle ? titleHeight : 0) + CGFloat(row) * (slotSize.height + spacing)
        )
    }

    private func slotPosition(at point: CGPoint) -> Int? {
        guard let presentation else { return nil }
        for slot in presentation.slots {
            let origin = Self.slotOrigin(position: slot.position, columns: presentation.columns, hasTitle: presentation.title != nil)
            let frame = CGRect(origin: CGPoint(x: presentation.origin.x + origin.x, y: presentation.origin.y + origin.y), size: Self.slotSize)
            if frame.contains(point) {
                return slot.position
            }
        }
        return nil
    }
}

struct MenuOverlay: View {
    @ObservedObject var controller: MenuController

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let presentation = controller.presentation {
                Color.black.opacity(0.35)
                    .contentShape(Rectangle())
                    .onTapGesture { controller.dismiss() }
                    .transition(.opacity.animation(Motion.powerTwoOut(Motion.overlayEnterMilliseconds)))
                MenuPanel(presentation: presentation, highlightedPosition: controller.highlightedPosition, armedPosition: controller.armedPosition) { position in
                    controller.activate(position)
                }
                .offset(x: presentation.origin.x, y: presentation.origin.y)
                .transition(.overlay)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea()
    }
}

private struct MenuPanel: View {
    let presentation: MenuController.Presentation
    let highlightedPosition: Int?
    let armedPosition: Int?
    let onSelect: (Int) -> Void

    var body: some View {
        let size = MenuController.panelSize(columns: presentation.columns, rows: presentation.rows, hasTitle: presentation.title != nil)
        ZStack(alignment: .topLeading) {
            Squircle.sheet.fill(Palette.panelSolid)
            Squircle.sheet.stroke(Palette.borderStrong, lineWidth: 1)
            if let title = presentation.title {
                MicroLabel(text: title)
                    .offset(x: MenuController.padding + 6, y: MenuController.padding + 4)
            }
            ForEach(presentation.slots) { slot in
                let origin = MenuController.slotOrigin(position: slot.position, columns: presentation.columns, hasTitle: presentation.title != nil)
                MenuSlotView(slot: slot, isHighlighted: highlightedPosition == slot.position, isArmed: armedPosition == slot.position)
                    .frame(width: MenuController.slotSize.width, height: MenuController.slotSize.height)
                    .contentShape(Rectangle())
                    .onTapGesture { onSelect(slot.position) }
                    .offset(x: origin.x, y: origin.y)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }
}

private struct MenuSlotView: View {
    let slot: MenuSlot
    let isHighlighted: Bool
    let isArmed: Bool

    private var fill: Color {
        if isArmed { return Palette.destructiveHard }
        if isHighlighted { return slot.tint }
        return Palette.sunken
    }

    private var ink: Color {
        if isArmed { return .white }
        if isHighlighted { return slot.swatch.map { Palette.isLight($0) ? Palette.ground : .white } ?? Palette.ground }
        return slot.swatch == nil ? slot.tint : Palette.textBody
    }

    var body: some View {
        ZStack(alignment: .leading) {
            Squircle.slot.fill(fill)
            Squircle.slot.stroke(slot.isActive ? slot.tint : Palette.border, lineWidth: slot.isActive ? 2 : 1)
            HStack(spacing: 10) {
                if let swatch = slot.swatch {
                    Circle()
                        .fill(Color(hex: swatch))
                        .frame(width: 22, height: 22)
                        .overlay(Circle().stroke(Palette.borderControl, lineWidth: 1))
                } else {
                    Rectangle()
                        .fill(isArmed || isHighlighted ? ink : slot.tint)
                        .frame(width: 4, height: 26)
                }
                Text((isArmed ? "Confirm" : slot.title).uppercased())
                    .font(Typography.mono(11))
                    .tracking(1.5)
                    .foregroundColor(ink)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 12)
        }
        .opacity(slot.isEnabled ? 1 : 0.38)
        .scaleEffect(isHighlighted ? 1.04 : 1)
        .animation(Motion.backOut(Motion.stateMilliseconds), value: isHighlighted)
        .animation(Motion.powerTwoOut(Motion.stateMilliseconds), value: isArmed)
    }
}
