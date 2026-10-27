import SwiftUI

struct StackGroupView: View {
    let group: TileGroup
    let caption: String
    let isOpen: Bool
    let cardHeight: (CGFloat) -> CGFloat
    let onToggle: (Bool) -> Void
    let onMenu: (CGPoint) -> Void
    let card: (String) -> AnyView

    @State private var width: CGFloat = 0
    @State private var time: CGFloat = 0
    @State private var isPulled = false

    private static let pullReach: CGFloat = 0.8
    private static let decideShare: CGFloat = 0.3

    var body: some View {
        StackGroupFrame(time: time, width: width, isOpening: isOpen && !isPulled, group: group, caption: caption, cardHeight: cardHeight, onToggle: onToggle, onMenu: onMenu, card: card)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(GeometryReader { proxy in
                Color.clear
                    .onAppear { width = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, next in width = next }
            })
            .simultaneousGesture(swipe)
            .onAppear { time = isOpen ? 1 : 0 }
            .onChange(of: isOpen) { _, open in run(to: open ? 1 : 0) }
    }

    private func run(to target: CGFloat) {
        let remaining = abs(target - time)
        withAnimation(.linear(duration: Motion.seconds(Motion.stackMilliseconds) * Double(remaining))) {
            time = target
        }
    }

    private var swipe: some Gesture {
        DragGesture(minimumDistance: 24)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height), width > 0 else { return }
                let share = value.translation.width / (width * Self.pullReach)
                if isOpen, share < 0 {
                    isPulled = true
                    time = min(1, max(0, 1 + share))
                } else if !isOpen, share > 0 {
                    isPulled = true
                    time = min(1, max(0, share))
                }
            }
            .onEnded { _ in
                guard isPulled else { return }
                isPulled = false
                if isOpen, 1 - time > Self.decideShare {
                    Haptics.tick()
                    onToggle(false)
                } else if !isOpen, time > Self.decideShare {
                    Haptics.tick()
                    onToggle(true)
                } else {
                    run(to: isOpen ? 1 : 0)
                }
            }
    }
}

private struct StackGroupFrame: View, Animatable {
    var time: CGFloat
    let width: CGFloat
    let isOpening: Bool
    let group: TileGroup
    let caption: String
    let cardHeight: (CGFloat) -> CGFloat
    let onToggle: (Bool) -> Void
    let onMenu: (CGPoint) -> Void
    let card: (String) -> AnyView

    private static let gap: CGFloat = 18
    private static let columns = 3
    private static let shutHeight: CGFloat = 150
    private static let headingHeight: CGFloat = 52
    private static let tiltDegrees: Double = 7
    private static let shift: CGFloat = 9
    private static let shrink: CGFloat = 0.05
    private static let darken: Double = 0.2
    private static let visibleLayers = 3
    private static let labelGap: CGFloat = 28
    private static let arrowSize: CGFloat = 44
    private static let arrowTurn: CGFloat = 0.5

    var animatableData: CGFloat {
        get { time }
        set { time = newValue }
    }

    private var count: Int { group.members.count }

    private var cell: CGFloat {
        max(1, (width - Self.gap * CGFloat(Self.columns - 1)) / CGFloat(Self.columns))
    }

    private func progress(_ index: Int) -> CGFloat {
        let span = CGFloat(Motion.shares.stackStagger)
        let start = CGFloat(index) / CGFloat(max(1, count)) * span
        let local = min(1, max(0, (time - start) / (1 - span)))
        return isOpening ? Motion.backOutValue(local) : Motion.powerThreeInOutValue(local)
    }

    private func depth(_ index: Int) -> Int {
        min(index, Self.visibleLayers - 1)
    }

    var body: some View {
        let height = cardHeight(cell)
        let shutScale = Self.shutHeight / max(1, height)
        let stackWidth = cell * shutScale + Self.shift * CGFloat(Self.visibleLayers - 1)
        let placements = group.members.indices.map { index -> (x: CGFloat, y: CGFloat, scale: CGFloat, rotation: Double, alpha: Double) in
            let shown = progress(index)
            let layer = depth(index)
            let openX = CGFloat(index % Self.columns) * (cell + Self.gap)
            let openY = Self.headingHeight + CGFloat(index / Self.columns) * (height + Self.gap)
            let shutX = Self.shift * CGFloat(layer)
            let startScale = shutScale * (1 - Self.shrink * CGFloat(layer))
            let shade = index >= Self.visibleLayers ? 0 : 1 - Self.darken * Double(layer)
            return (
                x: shutX + (openX - shutX) * shown,
                y: openY * shown,
                scale: startScale + (1 - startScale) * shown,
                rotation: Self.tiltDegrees * Double(layer) * Double(1 - shown),
                alpha: shade + (1 - shade) * Double(min(1, max(0, shown)))
            )
        }
        let reach = placements.map { $0.y + height * $0.scale }.max() ?? Self.shutHeight
        let frameHeight = max(Self.shutHeight * (1 - min(1, time)), reach)
        let arrowShutX = stackWidth + Self.labelGap * 0.5 - Self.arrowSize / 2
        let arrowOpenX = width - Self.arrowSize
        let arrowShown = min(1, max(0, time))
        let turn = min(1, max(0, (arrowShown - (1 - Self.arrowTurn) / 2) / Self.arrowTurn))
        ZStack(alignment: .topLeading) {
            ForEach(Array(group.members.enumerated()), id: \.element) { index, memberId in
                let placement = placements[index]
                card(memberId)
                    .frame(width: cell, height: height)
                    .scaleEffect(placement.scale, anchor: .topLeading)
                    .rotationEffect(.degrees(placement.rotation), anchor: .topLeading)
                    .opacity(placement.alpha)
                    .offset(x: placement.x, y: placement.y)
                    .zIndex(Double(count - index))
                    .allowsHitTesting(time >= 1)
            }
            shutLabel
                .frame(width: max(0, width - stackWidth - Self.labelGap), alignment: .leading)
                .mask(alignment: .trailing) {
                    Rectangle().frame(width: max(0, width - stackWidth - Self.labelGap) * (1 - arrowShown))
                }
                .offset(x: stackWidth + Self.labelGap, y: Self.shutHeight / 2 - 22)
            heading
                .opacity(Double(arrowShown))
                .frame(height: Self.headingHeight, alignment: .leading)
                .allowsHitTesting(time >= 1)
                .zIndex(Double(count + 1))
            GlyphView(name: "back", color: Palette.accent)
                .frame(width: Self.arrowSize, height: Self.arrowSize)
                .rotationEffect(.degrees(180 * Double(1 - turn)))
                .contentShape(Rectangle())
                .onTapGesture { onToggle(!isOpening) }
                .offset(x: arrowShutX + (arrowOpenX - arrowShutX) * arrowShown, y: (Self.shutHeight / 2 - Self.arrowSize / 2) * (1 - arrowShown) + (Self.headingHeight - Self.arrowSize) / 2 * arrowShown)
                .zIndex(Double(count + 2))
            if time <= 0 {
                TileInteraction(callbacks: TileCallbacks(onTap: { _ in onToggle(true) }, onMenu: onMenu))
                    .frame(width: max(0, width), height: Self.shutHeight)
                    .zIndex(Double(count + 1))
            }
        }
        .frame(width: max(0, width), height: frameHeight, alignment: .topLeading)
    }

    private var shutLabel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(group.title)
                .font(Typography.heading(19))
                .foregroundColor(Palette.textBright)
                .lineLimit(1)
            MicroLabel(text: caption)
        }
        .fixedSize()
    }

    private var heading: some View {
        HStack(spacing: 12) {
            GlyphView(name: "stack", color: Palette.accent, size: 18)
            Text(group.title.uppercased())
                .font(Typography.heading(19))
                .foregroundColor(Palette.textBright)
                .lineLimit(1)
            MicroLabel(text: caption)
        }
        .contentShape(Rectangle())
        .onTapGesture { onToggle(false) }
    }
}
