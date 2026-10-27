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
        let origin: CGPoint
        let isOnLeft: Bool
        let title: String?
    }

    static let rowSize = CGSize(width: 232, height: 54)
    static let spacing: CGFloat = 6
    static let padding: CGFloat = 8
    static let titleHeight: CGFloat = 26
    static let screenMargin: CGFloat = 16
    static let fingerGap: CGFloat = 18

    @Published private(set) var presentation: Presentation?
    @Published private(set) var highlightedPosition: Int?
    @Published private(set) var armedPosition: Int?
    var screenSize: CGSize = CGSize(width: 1024, height: 1366)

    func present(_ slots: [MenuSlot], at point: CGPoint, title: String? = nil) {
        let ordered = slots.sorted { $0.position < $1.position }
        let size = Self.panelSize(rows: ordered.count, hasTitle: title != nil)
        let isOnLeft = point.x + Self.fingerGap + size.width > screenSize.width - Self.screenMargin
        var origin = CGPoint(x: isOnLeft ? point.x - Self.fingerGap - size.width : point.x + Self.fingerGap, y: point.y - size.height / 2)
        origin.x = min(max(Self.screenMargin, origin.x), screenSize.width - size.width - Self.screenMargin)
        origin.y = min(max(Self.screenMargin, origin.y), screenSize.height - size.height - Self.screenMargin)
        armedPosition = nil
        highlightedPosition = nil
        withAnimation(Motion.backOut(Motion.overlayEnterMilliseconds)) {
            presentation = Presentation(slots: ordered, origin: origin, isOnLeft: isOnLeft, title: title)
        }
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

    static func panelSize(rows: Int, hasTitle: Bool) -> CGSize {
        CGSize(
            width: padding * 2 + rowSize.width,
            height: padding * 2 + CGFloat(rows) * rowSize.height + CGFloat(max(0, rows - 1)) * spacing + (hasTitle ? titleHeight : 0)
        )
    }

    static func rowOrigin(index: Int, hasTitle: Bool) -> CGPoint {
        CGPoint(x: padding, y: padding + (hasTitle ? titleHeight : 0) + CGFloat(index) * (rowSize.height + spacing))
    }

    private func slotPosition(at point: CGPoint) -> Int? {
        guard let presentation else { return nil }
        for (index, slot) in presentation.slots.enumerated() {
            let origin = Self.rowOrigin(index: index, hasTitle: presentation.title != nil)
            let frame = CGRect(origin: CGPoint(x: presentation.origin.x + origin.x, y: presentation.origin.y + origin.y), size: Self.rowSize)
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
                .transition(.asymmetric(
                    insertion: AnyTransition.scale(scale: 0.001, anchor: presentation.isOnLeft ? .trailing : .leading).combined(with: .opacity).animation(Motion.backOut(Motion.overlayEnterMilliseconds)),
                    removal: AnyTransition.scale(scale: 0.001, anchor: presentation.isOnLeft ? .trailing : .leading).combined(with: .opacity).animation(Motion.backIn(Motion.overlayLeaveMilliseconds))
                ))
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

    @State private var isShown = false

    var body: some View {
        let hasTitle = presentation.title != nil
        let size = MenuController.panelSize(rows: presentation.slots.count, hasTitle: hasTitle)
        ZStack(alignment: .topLeading) {
            Squircle.sheet.fill(Palette.panelSolid)
            Squircle.sheet.stroke(Palette.borderStrong, lineWidth: 1)
            if let title = presentation.title {
                MicroLabel(text: title)
                    .offset(x: MenuController.padding + 6, y: MenuController.padding + 4)
            }
            ForEach(Array(presentation.slots.enumerated()), id: \.element.id) { index, slot in
                let origin = MenuController.rowOrigin(index: index, hasTitle: hasTitle)
                MenuSlotView(slot: slot, isHighlighted: highlightedPosition == slot.position, isArmed: armedPosition == slot.position)
                    .frame(width: MenuController.rowSize.width, height: MenuController.rowSize.height)
                    .contentShape(Rectangle())
                    .onTapGesture { onSelect(slot.position) }
                    .scaleEffect(isShown ? 1 : 0.001)
                    .opacity(isShown ? 1 : 0)
                    .animation(Motion.backOut(Motion.stateMilliseconds, delay: Motion.riseDelayMilliseconds + index * Motion.riseStaggerMilliseconds), value: isShown)
                    .offset(x: origin.x, y: origin.y)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .onAppear { isShown = true }
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
