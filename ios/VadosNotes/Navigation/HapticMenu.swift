import SwiftUI

struct MenuSlot: Identifiable {
    let position: Int
    let title: String
    let role: MenuRole
    var glyph: String?
    var section = 0
    var rank = 0
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

    private static let arrangement: [String: (section: Int, rank: Int, glyph: String)] = [
        "rename": (0, 0, "pencil"),
        "appearance": (0, 1, "star"),
        "group": (1, 0, "stack"),
        "ungroup": (1, 0, "stack"),
        "move": (1, 1, "move"),
        "expand_columns": (0, 0, "add_column"),
        "expand_rows": (0, 1, "add_row"),
        "toggle_guides": (1, 0, "guides"),
        "toggle_dividers": (1, 1, "cell_lines"),
        "delete_notebook": (2, 0, "trash"),
        "delete_page": (2, 0, "trash"),
    ]

    static func fromTokens(_ tokens: [Tokens.MenuSlotToken], title: (String) -> String, isEnabled: (String) -> Bool = { _ in true }, perform: @escaping (String) -> Void) -> [MenuSlot] {
        tokens.map { token in
            let arranged = arrangement[token.action]
            return MenuSlot(
                position: token.slot,
                title: title(token.action),
                role: MenuRole(rawValue: token.role) ?? .view,
                glyph: arranged?.glyph,
                section: arranged?.section ?? 0,
                rank: arranged?.rank ?? token.slot,
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
        let rows: [CGRect]
        let dividers: [CGFloat]
        let size: CGSize
        let origin: CGPoint
        let isOnLeft: Bool
        let title: String?
    }

    static let rowSize = CGSize(width: 184, height: 46)
    static let spacing: CGFloat = 4
    static let dividerGap: CGFloat = 13
    static let padding: CGFloat = 6
    static let titleHeight: CGFloat = 26
    static let screenMargin: CGFloat = 16
    static let fingerGap: CGFloat = 14

    @Published private(set) var presentation: Presentation?
    @Published private(set) var highlightedPosition: Int?
    @Published private(set) var armedPosition: Int?
    var screenSize: CGSize = CGSize(width: 1024, height: 1366)

    func present(_ slots: [MenuSlot], at point: CGPoint, title: String? = nil) {
        let ordered = slots.sorted { first, second in
            if first.isDestructive != second.isDestructive { return second.isDestructive }
            if first.section != second.section { return first.section < second.section }
            if first.rank != second.rank { return first.rank < second.rank }
            return first.position < second.position
        }
        var rows: [CGRect] = []
        var dividers: [CGFloat] = []
        var top = Self.padding + (title != nil ? Self.titleHeight : 0)
        for (index, slot) in ordered.enumerated() {
            if index > 0 {
                let previous = ordered[index - 1]
                if previous.section != slot.section || previous.isDestructive != slot.isDestructive {
                    dividers.append(top + (Self.dividerGap - Self.spacing) / 2)
                    top += Self.dividerGap - Self.spacing
                }
            }
            rows.append(CGRect(origin: CGPoint(x: Self.padding, y: top), size: Self.rowSize))
            top += Self.rowSize.height + Self.spacing
        }
        let size = CGSize(width: Self.padding * 2 + Self.rowSize.width, height: top - Self.spacing + Self.padding)
        let isOnLeft = point.x + Self.fingerGap + size.width > screenSize.width - Self.screenMargin
        var origin = CGPoint(x: isOnLeft ? point.x - Self.fingerGap - size.width : point.x + Self.fingerGap, y: point.y)
        if origin.y + size.height > screenSize.height - Self.screenMargin {
            origin.y = point.y - size.height
        }
        origin.x = min(max(Self.screenMargin, origin.x), screenSize.width - size.width - Self.screenMargin)
        origin.y = min(max(Self.screenMargin, origin.y), screenSize.height - size.height - Self.screenMargin)
        armedPosition = nil
        highlightedPosition = nil
        withAnimation(Motion.powerTwoOut(Motion.overlayEnterMilliseconds)) {
            presentation = Presentation(slots: ordered, rows: rows, dividers: dividers, size: size, origin: origin, isOnLeft: isOnLeft, title: title)
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

    private func slotPosition(at point: CGPoint) -> Int? {
        guard let presentation else { return nil }
        for (index, slot) in presentation.slots.enumerated() {
            let frame = presentation.rows[index].offsetBy(dx: presentation.origin.x, dy: presentation.origin.y)
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
                .transition(.asymmetric(
                    insertion: AnyTransition.scale(scale: 0.001, anchor: presentation.isOnLeft ? .topTrailing : .topLeading).combined(with: .opacity).animation(Motion.powerTwoOut(Motion.overlayEnterMilliseconds)),
                    removal: AnyTransition.scale(scale: 0.001, anchor: presentation.isOnLeft ? .topTrailing : .topLeading).combined(with: .opacity).animation(Motion.backIn(Motion.overlayLeaveMilliseconds))
                ))
                .alignmentGuide(.leading) { _ in -presentation.origin.x }
                .alignmentGuide(.top) { _ in -presentation.origin.y }
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
        ZStack(alignment: .topLeading) {
            Squircle.sheet.fill(Palette.panelSolid)
            Squircle.sheet.stroke(Palette.borderStrong, lineWidth: 1)
            if let title = presentation.title {
                MicroLabel(text: title)
                    .lineLimit(1)
                    .frame(width: MenuController.rowSize.width - 12, alignment: .leading)
                    .offset(x: MenuController.padding + 6, y: MenuController.padding + 4)
            }
            ForEach(Array(presentation.dividers.enumerated()), id: \.offset) { _, y in
                Rectangle()
                    .fill(Palette.borderStrong)
                    .frame(width: MenuController.rowSize.width - 24, height: 1)
                    .offset(x: MenuController.padding + 12, y: y)
                    .opacity(isShown ? 1 : 0)
                    .animation(Motion.powerTwoOut(Motion.stateMilliseconds, delay: Motion.riseDelayMilliseconds), value: isShown)
            }
            ForEach(Array(presentation.slots.enumerated()), id: \.element.id) { index, slot in
                let row = presentation.rows[index]
                MenuSlotView(slot: slot, isHighlighted: highlightedPosition == slot.position, isArmed: armedPosition == slot.position)
                    .frame(width: row.width, height: row.height)
                    .contentShape(Rectangle())
                    .onTapGesture { onSelect(slot.position) }
                    .scaleEffect(isShown ? 1 : 0.001)
                    .opacity(isShown ? 1 : 0)
                    .animation(Motion.powerTwoOut(Motion.stateMilliseconds, delay: Motion.riseDelayMilliseconds + index * Motion.riseStaggerMilliseconds), value: isShown)
                    .offset(x: row.minX, y: row.minY)
            }
        }
        .frame(width: presentation.size.width, height: presentation.size.height, alignment: .topLeading)
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
                        .frame(width: 20, height: 20)
                        .overlay(Circle().stroke(Palette.borderControl, lineWidth: 1))
                } else if let glyph = slot.glyph {
                    GlyphView(name: isArmed ? "check" : glyph, color: ink, size: 18)
                        .frame(width: 20, height: 20)
                } else {
                    Rectangle()
                        .fill(isArmed || isHighlighted ? ink : slot.tint)
                        .frame(width: 4, height: 22)
                }
                Text((isArmed ? "Confirm" : slot.title).uppercased())
                    .font(Typography.mono(11))
                    .tracking(1.2)
                    .foregroundColor(ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .padding(.horizontal, 12)
        }
        .opacity(slot.isEnabled ? 1 : 0.38)
        .scaleEffect(isHighlighted ? 1.04 : 1)
        .animation(Motion.backOut(Motion.stateMilliseconds), value: isHighlighted)
        .animation(Motion.powerTwoOut(Motion.stateMilliseconds), value: isArmed)
    }
}
