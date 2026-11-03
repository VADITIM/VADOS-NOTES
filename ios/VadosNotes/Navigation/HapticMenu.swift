import SwiftUI
import UIKit

struct MenuSlot: Identifiable {
    let position: Int
    let title: String
    let role: MenuRole
    var glyph: String?
    var section = 0
    var rank = 0
    var lane = 0
    var isIconOnly = false
    var swatch: String?
    var isEnabled = true
    var isActive = false
    let handler: () -> Void

    var id: Int { position }

    var isDestructive: Bool { role == .destructive }

    var isTrailing: Bool { isDestructive && lane == 0 }

    var tint: Color {
        if let swatch {
            return Color(hex: swatch)
        }
        return Palette.color(for: role)
    }

    private static let swatchesPerLine = 4

    private struct Arrangement {
        let section: Int
        let rank: Int
        let glyph: String
        var lane = 0
        var isIconOnly = false
    }

    private static let arrangement: [String: Arrangement] = [
        "rename": Arrangement(section: 0, rank: 0, glyph: "pencil"),
        "appearance": Arrangement(section: 0, rank: 0, glyph: "star", lane: 1),
        "new_folder": Arrangement(section: 0, rank: 1, glyph: "folder_add"),
        "new_note": Arrangement(section: 0, rank: 1, glyph: "note_add", lane: 1),
        "group": Arrangement(section: 1, rank: 0, glyph: "stack"),
        "ungroup": Arrangement(section: 1, rank: 0, glyph: "stack"),
        "move": Arrangement(section: 1, rank: 1, glyph: "move"),
        "paste": Arrangement(section: 0, rank: 0, glyph: "paste"),
        "expand_columns": Arrangement(section: 1, rank: 0, glyph: "add_column"),
        "shrink_columns": Arrangement(section: 1, rank: 0, glyph: "remove_column", lane: 1, isIconOnly: true),
        "expand_rows": Arrangement(section: 1, rank: 1, glyph: "add_row"),
        "shrink_rows": Arrangement(section: 1, rank: 1, glyph: "remove_row", lane: 1, isIconOnly: true),
        "toggle_guides": Arrangement(section: 2, rank: 0, glyph: "guides"),
        "toggle_dividers": Arrangement(section: 2, rank: 1, glyph: "cell_lines"),
        "invert_import": Arrangement(section: 2, rank: 2, glyph: "invert"),
        "delete_notebook": Arrangement(section: 3, rank: 0, glyph: "trash"),
        "delete_page": Arrangement(section: 3, rank: 0, glyph: "trash"),
        "cut": Arrangement(section: 0, rank: 0, glyph: "cut", isIconOnly: true),
        "copy": Arrangement(section: 0, rank: 0, glyph: "copy", lane: 1, isIconOnly: true),
        "duplicate": Arrangement(section: 0, rank: 0, glyph: "duplicate", lane: 2),
        "color": Arrangement(section: 1, rank: 0, glyph: "color"),
        "equal_width": Arrangement(section: 1, rank: 0, glyph: "equal_width", lane: 1),
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
                lane: arranged?.lane ?? 0,
                isIconOnly: arranged?.isIconOnly ?? false,
                isEnabled: isEnabled(token.action),
                handler: { perform(token.action) }
            )
        }
    }

    static func swatches(_ colors: [String], current: String?, perform: @escaping (String) -> Void) -> [MenuSlot] {
        colors.enumerated().map { index, color in
            MenuSlot(position: index, title: color, role: .edit, rank: index / swatchesPerLine, lane: index % swatchesPerLine, isIconOnly: true, swatch: color, isActive: color.uppercased() == current?.uppercased(), handler: { perform(color) })
        }
    }
}

@MainActor
final class MenuController: ObservableObject {
    struct Presentation {
        let lines: [[MenuSlot]]
        let anchor: CGPoint
        let isOnLeft: Bool
        let title: String?
        let identity: Int

        var slots: [MenuSlot] { lines.flatMap { $0 } }
    }

    struct Layout {
        let frames: [Int: CGRect]
        let titleFrame: CGRect?
        let size: CGSize
    }

    static let chipHeight: CGFloat = 44
    static let titleHeight: CGFloat = 28
    static let spacing: CGFloat = 6
    static let sectionGap: CGFloat = 14
    static let screenMargin: CGFloat = 16
    static let fingerGap: CGFloat = 14
    static let iconSize: CGFloat = 18
    static let iconGap: CGFloat = 9
    static let leadingPadding: CGFloat = 14
    static let trailingPadding: CGFloat = 18
    static let titlePadding: CGFloat = 14
    static let armedSeconds: Double = 2.4

    static var leaveMilliseconds: Int {
        Motion.navigationLeaveElementMilliseconds + Motion.navigationLeaveSpreadMilliseconds * 3 / 4 + Motion.navigationLeavePopMilliseconds
    }

    @Published private(set) var presentation: Presentation?
    @Published private(set) var highlightedPosition: Int?
    @Published private(set) var armedPosition: Int?
    @Published private(set) var widenedPosition: Int?
    @Published private(set) var isLeaving = false
    var screenSize: CGSize = CGSize(width: 1024, height: 1366)
    private var identity = 0
    private var armWork: DispatchWorkItem?

    var isPresented: Bool { presentation != nil && !isLeaving }

    func present(_ slots: [MenuSlot], at point: CGPoint, title: String? = nil) {
        let ordered = slots.sorted { first, second in
            if first.isTrailing != second.isTrailing { return second.isTrailing }
            if first.section != second.section { return first.section < second.section }
            if first.rank != second.rank { return first.rank < second.rank }
            if first.lane != second.lane { return first.lane < second.lane }
            return first.position < second.position
        }
        var lines: [[MenuSlot]] = []
        for slot in ordered {
            if slot.lane > 0, let previous = lines.last?.first, previous.section == slot.section, previous.rank == slot.rank, !previous.isTrailing {
                lines[lines.count - 1].append(slot)
            } else {
                lines.append([slot])
            }
        }
        armWork?.cancel()
        armedPosition = nil
        widenedPosition = nil
        highlightedPosition = nil
        isLeaving = false
        identity += 1
        let size = Self.layout(lines: lines, title: title, isOnLeft: false, widened: nil).size
        let isOnLeft = point.x + Self.fingerGap + size.width > screenSize.width - Self.screenMargin
        var top = point.y
        if top + size.height > screenSize.height - Self.screenMargin {
            top = point.y - size.height
        }
        top = min(max(Self.screenMargin, top), screenSize.height - size.height - Self.screenMargin)
        let anchorX = isOnLeft ? point.x - Self.fingerGap : point.x + Self.fingerGap
        presentation = Presentation(lines: lines, anchor: CGPoint(x: anchorX, y: top), isOnLeft: isOnLeft, title: title, identity: identity)
    }

    func layout(for presentation: Presentation) -> Layout {
        Self.layout(lines: presentation.lines, title: presentation.title, isOnLeft: presentation.isOnLeft, widened: widenedPosition)
    }

    func origin(for presentation: Presentation, layout: Layout) -> CGPoint {
        let left = presentation.isOnLeft ? presentation.anchor.x - layout.size.width : presentation.anchor.x
        let clamped = min(max(Self.screenMargin, left), screenSize.width - layout.size.width - Self.screenMargin)
        return CGPoint(x: clamped, y: presentation.anchor.y)
    }

    private static func layout(lines: [[MenuSlot]], title: String?, isOnLeft: Bool, widened: Int?) -> Layout {
        var widest: CGFloat = 0
        var top: CGFloat = 0
        var titleWidth: CGFloat = 0
        if let title {
            titleWidth = ceil(textWidth(title.uppercased(), size: 10, kern: 3)) + titlePadding * 2
            widest = titleWidth
            top = titleHeight + spacing
        }
        var placed: [(position: Int, y: CGFloat, width: CGFloat, offset: CGFloat, lineWidth: CGFloat)] = []
        for (index, line) in lines.enumerated() {
            if index > 0, let previous = lines[index - 1].first, let first = line.first, previous.section != first.section || previous.isTrailing != first.isTrailing {
                top += sectionGap - spacing
            }
            let widths = line.map { chipWidth($0, isArmed: $0.position == widened) }
            let lineWidth = widths.reduce(0, +) + spacing * CGFloat(max(0, line.count - 1))
            widest = max(widest, lineWidth)
            var offset: CGFloat = 0
            for (lane, slot) in line.enumerated() {
                placed.append((slot.position, top, widths[lane], offset, lineWidth))
                offset += widths[lane] + spacing
            }
            top += chipHeight + spacing
        }
        var frames: [Int: CGRect] = [:]
        for item in placed {
            let x = isOnLeft ? widest - item.lineWidth + item.offset : item.offset
            frames[item.position] = CGRect(x: x, y: item.y, width: item.width, height: chipHeight)
        }
        let titleFrame = title == nil ? nil : CGRect(x: isOnLeft ? widest - titleWidth : 0, y: 0, width: titleWidth, height: titleHeight)
        return Layout(frames: frames, titleFrame: titleFrame, size: CGSize(width: widest, height: max(0, top - spacing)))
    }

    static func chipWidth(_ slot: MenuSlot, isArmed: Bool) -> CGFloat {
        if slot.isIconOnly && !isArmed {
            return chipHeight
        }
        let text = (isArmed ? "Confirm" : slot.title).uppercased()
        let hasIcon = isArmed || slot.glyph != nil || slot.swatch != nil
        let width = leadingPadding + (hasIcon ? iconSize + iconGap : 0) + textWidth(text, size: 11, kern: 1.2) + trailingPadding
        return max(chipHeight, ceil(width))
    }

    private static func textWidth(_ text: String, size: CGFloat, kern: CGFloat) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: Typography.monoFont(size), .kern: kern]).width
    }

    func drag(to point: CGPoint) {
        guard isPresented else { return }
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
        guard isPresented, let slot = presentation?.slots.first(where: { $0.position == position }), slot.isEnabled else { return }
        if slot.isDestructive && armedPosition != position {
            setArmed(position)
            Haptics.tick()
            return
        }
        dismiss()
        Haptics.landed()
        slot.handler()
    }

    private func setArmed(_ position: Int?) {
        armWork?.cancel()
        armedPosition = position
        let current = identity
        DispatchQueue.main.asyncAfter(deadline: .now() + Motion.seconds(Motion.navigationMutateLeaveMilliseconds)) { [weak self] in
            guard let self, self.identity == current, self.armedPosition == position else { return }
            withAnimation(Motion.powerThreeInOut(Motion.navigationSwitchMilliseconds * 2)) {
                self.widenedPosition = position
            }
        }
        guard position != nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.identity == current else { return }
            self.setArmed(nil)
        }
        armWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.armedSeconds, execute: work)
    }

    func dismiss() {
        guard presentation != nil, !isLeaving else { return }
        armWork?.cancel()
        isLeaving = true
        highlightedPosition = nil
        let current = identity
        DispatchQueue.main.asyncAfter(deadline: .now() + Motion.seconds(Self.leaveMilliseconds)) { [weak self] in
            guard let self, self.identity == current else { return }
            self.presentation = nil
            self.armedPosition = nil
            self.widenedPosition = nil
            self.isLeaving = false
        }
    }

    private func slotPosition(at point: CGPoint) -> Int? {
        guard let presentation else { return nil }
        let layout = layout(for: presentation)
        let origin = origin(for: presentation, layout: layout)
        for slot in presentation.slots {
            if let frame = layout.frames[slot.position]?.offsetBy(dx: origin.x, dy: origin.y), frame.contains(point) {
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
                let layout = controller.layout(for: presentation)
                let origin = controller.origin(for: presentation, layout: layout)
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture { controller.dismiss() }
                    .allowsHitTesting(!controller.isLeaving)
                ZStack(alignment: .topLeading) {
                    if let title = presentation.title, let frame = layout.titleFrame {
                        MenuTitleChip(title: title, isLeaving: controller.isLeaving)
                            .frame(width: frame.width, height: frame.height)
                            .offset(x: frame.minX, y: frame.minY)
                    }
                    ForEach(Array(presentation.slots.enumerated()), id: \.element.id) { index, slot in
                        let frame = layout.frames[slot.position] ?? .zero
                        MenuChip(
                            slot: slot,
                            isHighlighted: controller.highlightedPosition == slot.position,
                            isArmed: controller.armedPosition == slot.position,
                            isLeaving: controller.isLeaving,
                            enterDelay: (index + (presentation.title == nil ? 0 : 1)) * Motion.riseStaggerMilliseconds
                        ) {
                            controller.activate(slot.position)
                        }
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                        .animation(Motion.powerThreeInOut(Motion.navigationSwitchMilliseconds * 2), value: frame)
                    }
                }
                .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
                .offset(x: origin.x, y: origin.y)
                .animation(Motion.powerThreeInOut(Motion.navigationSwitchMilliseconds * 2), value: origin)
                .allowsHitTesting(!controller.isLeaving)
                .id(presentation.identity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea()
    }
}

private struct MenuTitleChip: View {
    let title: String
    let isLeaving: Bool

    @StateObject private var motion = PillMotion()

    var body: some View {
        ZStack {
            PillShell(scale: motion.shellScale, spread: motion.shellSpread, isWide: true, fill: Palette.sunken)
            MicroLabel(text: title)
                .padding(.horizontal, MenuController.titlePadding)
                .revealedElement()
        }
        .environment(\.isElementRevealed, motion.areElementsShown)
        .opacity(motion.isPresent ? 1 : 0)
        .allowsHitTesting(false)
        .onAppear { motion.enter() }
        .onChange(of: isLeaving) { _, leaving in
            if leaving {
                motion.leave()
            }
        }
    }
}

private struct MenuChip: View {
    let slot: MenuSlot
    let isHighlighted: Bool
    let isArmed: Bool
    let isLeaving: Bool
    let enterDelay: Int
    let onSelect: () -> Void

    @StateObject private var motion = PillMotion()
    @State private var shownArmed = false

    private var fill: Color {
        if isArmed { return Palette.destructiveHard }
        if isHighlighted { return slot.tint }
        return Palette.panelSolid
    }

    private var stroke: Color {
        if isArmed { return Palette.destructiveHard }
        if slot.isActive { return Palette.accent }
        return Palette.borderControl
    }

    private var ink: Color {
        if shownArmed { return .white }
        if isHighlighted { return slot.swatch.map { Palette.isLight($0) ? Palette.ground : .white } ?? Palette.ground }
        return slot.swatch == nil ? slot.tint : Palette.textBody
    }

    private var isCircle: Bool { slot.isIconOnly && !shownArmed }

    var body: some View {
        ZStack {
            PillShell(scale: motion.shellScale, spread: motion.shellSpread, isWide: true, stroke: stroke, fill: fill)
                .animation(Motion.powerTwoOut(Motion.pressMilliseconds), value: fill)
            content
                .revealedElement()
        }
        .environment(\.isElementRevealed, motion.areElementsShown)
        .environment(\.isElementMutating, motion.isMutating)
        .opacity(motion.isPresent ? (slot.isEnabled ? 1 : 0.38) : 0)
        .scaleEffect(isHighlighted ? 1.06 : 1)
        .animation(Motion.backOut(Motion.stateMilliseconds), value: isHighlighted)
        .contentShape(Capsule())
        .onTapGesture(perform: onSelect)
        .allowsHitTesting(motion.areElementsShown || motion.isMutating)
        .accessibilityLabel(slot.title)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + Motion.seconds(enterDelay)) {
                if !isLeaving {
                    motion.enter()
                }
            }
        }
        .onChange(of: isArmed) { _, armed in
            motion.mutate { shownArmed = armed }
        }
        .onChange(of: isLeaving) { _, leaving in
            if leaving {
                motion.leave()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if isCircle {
            icon
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HStack(spacing: MenuController.iconGap) {
                if shownArmed || slot.glyph != nil || slot.swatch != nil {
                    icon
                }
                Text((shownArmed ? "Confirm" : slot.title).uppercased())
                    .font(Typography.mono(11))
                    .tracking(1.2)
                    .foregroundColor(ink)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.leading, MenuController.leadingPadding)
            .padding(.trailing, MenuController.trailingPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var icon: some View {
        if let swatch = slot.swatch, !shownArmed {
            Circle()
                .fill(Color(hex: swatch))
                .frame(width: 22, height: 22)
                .overlay(Circle().stroke(Palette.borderControl, lineWidth: 1))
        } else if let glyph = shownArmed ? "check" : slot.glyph {
            GlyphView(name: glyph, color: ink, size: MenuController.iconSize)
                .frame(width: MenuController.iconSize, height: MenuController.iconSize)
        }
    }
}
