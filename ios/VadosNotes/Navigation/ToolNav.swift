import SwiftUI

struct NavItem: Identifiable {
    let id: String
    var glyph: String = ""
    var caption: String?
    var label: String
    var tint: Color = Palette.textBright
    var isTinted = false
    var isEnabled = true
    var swatch: Color?
    var action: (CGRect) -> Void
}

struct SubNavigationGroup: Identifiable {
    let id: String
    let content: (NavOrientation) -> AnyView
}

private struct NavSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero {
            value = next
        }
    }
}

private struct SubNavSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero {
            value = next
        }
    }
}

private struct PanelSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero {
            value = next
        }
    }
}

private struct GroupExtentKey: PreferenceKey {
    static var defaultValue: [String: CGSize] = [:]
    static func reduce(value: inout [String: CGSize], nextValue: () -> [String: CGSize]) {
        value.merge(nextValue()) { _, next in next }
    }
}

enum NavMetrics {
    static let scale: CGFloat = 1.7
    static let edgeMargin: CGFloat = 16
    static let bottomGap: CGFloat = 24
    static let besideGap: CGFloat = 10
    static let avoidGap: CGFloat = 12
    static let padding: CGFloat = 5 * scale
    static let spacing: CGFloat = 2 * scale
    static let glyphSize: CGFloat = 22 * scale
    static let gripLength: CGFloat = 18 * scale
    static let layerSpace = "navLayer"

    static func itemSize(_ orientation: NavOrientation) -> CGSize {
        orientation == .horizontal ? CGSize(width: 56 * scale, height: 48 * scale) : CGSize(width: 48 * scale, height: 52 * scale)
    }

    static func along(_ size: CGSize, _ orientation: NavOrientation) -> CGFloat {
        orientation == .horizontal ? size.width : size.height
    }
}

enum NavSide {
    case up
    case down
    case left
    case right
}

private struct Reordering {
    let id: String
    var order: [String]
    var anchor: CGFloat
    var offset: CGFloat
}

struct ToolNav<PanelContent: View>: View {
    let face: String
    let groups: [[NavItem]]
    let selectedId: String?
    let subNavKey: String?
    let subNavigationGroups: [SubNavigationGroup]
    let panelKey: String?
    let obstacles: [CGRect]
    let keyboardHeight: CGFloat
    let isShown: Bool
    let onReorderTools: ([String]) -> Void
    let onReorderSubNavigation: ([String]) -> Void
    @ViewBuilder var panel: () -> PanelContent

    @Namespace private var washSpace
    @State private var orientation: NavOrientation = .horizontal
    @State private var placement: NavPlacement?
    @State private var navSize: CGSize = .zero
    @State private var subNavSize: CGSize = .zero
    @State private var panelSize: CGSize = .zero
    @State private var groupSizes: [String: CGSize] = [:]
    @State private var carryPoint: CGPoint?
    @State private var carryGrab: CGSize = .zero
    @State private var swallowUntil = Date.distantPast
    @State private var shownSubNavigationKey: String?
    @State private var isRetracting = false
    @State private var toolReordering: Reordering?
    @State private var groupReordering: Reordering?

    private enum Entry: Identifiable {
        case item(NavItem)
        case separator(String)

        var id: String {
            switch self {
            case .item(let item): return item.id
            case .separator(let id): return id
            }
        }
    }

    private var toolIds: [String] {
        toolReordering?.order ?? groups.first?.map(\.id) ?? []
    }

    private var entries: [Entry] {
        var entries: [Entry] = []
        for (index, group) in groups.enumerated() where !group.isEmpty {
            if !entries.isEmpty {
                entries.append(.separator("separator-\(face)-\(index)"))
            }
            if index == 0 {
                entries.append(contentsOf: toolIds.compactMap { id in group.first { $0.id == id } }.map(Entry.item))
            } else {
                entries.append(contentsOf: group.map(Entry.item))
            }
        }
        return entries
    }

    private var orderedSubNavigationGroups: [SubNavigationGroup] {
        guard let order = groupReordering?.order else { return subNavigationGroups }
        return order.compactMap { id in subNavigationGroups.first { $0.id == id } }
    }

    var body: some View {
        GeometryReader { proxy in
            let layer = proxy.size
            let layerOrigin = proxy.frame(in: .global).origin
            let blocked = localObstacles(origin: layerOrigin, layer: layer)
            let center = navCenter(in: layer, blocked: blocked)
            let navigationRect = rect(center: center, size: navSize)
            let side = outwardSide(center: center, layer: layer)
            let subNavCenter = placeBeside(navigationRect, size: subNavSize, side: side, layer: layer, blocked: blocked + [navigationRect])
            let subNavRect = rect(center: subNavCenter, size: subNavSize)
            ZStack(alignment: .topLeading) {
                if shownSubNavigationKey != nil, carryPoint == nil, isShown {
                    subNavBody
                        .position(subNavCenter)
                        .transition(.popTogether)
                    if let panelKey, !isRetracting {
                        panel()
                            .fixedSize()
                            .background(GeometryReader { panelProxy in Color.clear.preference(key: PanelSizeKey.self, value: panelProxy.size) })
                            .id(panelKey)
                            .position(placeBeside(subNavRect, size: panelSize, side: side, layer: layer, blocked: blocked + [navigationRect, subNavRect]))
                            .transition(.popTogether)
                    }
                }
                navBody(layer: layer, center: center)
                    .position(center)
            }
            .animation(carryPoint == nil ? Motion.placement : nil, value: center)
            .animation(Motion.placement, value: subNavCenter)
            .coordinateSpace(name: NavMetrics.layerSpace)
            .onPreferenceChange(NavSizeKey.self) { navSize = $0 }
            .onPreferenceChange(SubNavSizeKey.self) { subNavSize = $0 }
            .onPreferenceChange(PanelSizeKey.self) { panelSize = $0 }
            .onPreferenceChange(GroupExtentKey.self) { groupSizes = $0 }
        }
        .onAppear {
            placement = Preferences.shared.navPlacement
            orientation = placement?.orientation == NavOrientation.vertical.rawValue ? .vertical : .horizontal
            shownSubNavigationKey = subNavKey
        }
        .onChange(of: subNavKey) { _, key in
            if key != nil {
                withAnimation(Motion.backOut(Motion.stateMilliseconds)) {
                    isRetracting = false
                    shownSubNavigationKey = key
                }
                return
            }
            withAnimation(Motion.powerThreeInOut(Motion.stateMilliseconds)) {
                isRetracting = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Motion.seconds(Motion.stateMilliseconds)) {
                guard subNavKey == nil else { return }
                withAnimation(Motion.backIn(Motion.stateMilliseconds)) {
                    shownSubNavigationKey = nil
                    isRetracting = false
                }
            }
        }
    }

    private func navBody(layer: CGSize, center: CGPoint) -> some View {
        let layout = orientation == .horizontal ? AnyLayout(HStackLayout(spacing: NavMetrics.spacing)) : AnyLayout(VStackLayout(spacing: NavMetrics.spacing))
        return layout {
            grip(layer: layer, center: center)
            ForEach(entries) { entry in
                switch entry {
                case .item(let item):
                    itemButton(item)
                        .transition(.pop)
                case .separator:
                    NavSeparator(orientation: orientation)
                        .transition(.pop)
                }
            }
            grip(layer: layer, center: center)
        }
        .animation(Motion.wash, value: selectedId)
        .animation(Motion.placement, value: toolIds)
        .padding(NavMetrics.padding)
        .background(Capsule().fill(Palette.panelSolid))
        .overlay(Capsule().stroke(carryPoint == nil ? Palette.border : Palette.accent, lineWidth: 1))
        .fixedSize()
        .background(GeometryReader { navProxy in Color.clear.preference(key: NavSizeKey.self, value: navProxy.size) })
        .scaleEffect(carryPoint == nil ? 1 : CGFloat(Motion.scales.held))
        .shadow(color: .black.opacity(0.45), radius: 16, y: 12)
        .modifier(ChromePop(isShown: isShown, order: 1, anchor: .center))
        .animation(Motion.powerThreeInOut(Motion.stateMilliseconds * 2), value: face)
        .animation(Motion.backOut(Motion.stateMilliseconds), value: carryPoint == nil)
    }

    private func grip(layer: CGSize, center: CGPoint) -> some View {
        let size = NavMetrics.itemSize(orientation)
        return GlyphView(name: "grip", color: carryPoint == nil ? Palette.textFaint : Palette.accent, size: NavMetrics.glyphSize * 0.7)
            .rotationEffect(orientation == .horizontal ? .zero : .degrees(90))
            .frame(width: orientation == .horizontal ? NavMetrics.gripLength : size.width, height: orientation == .horizontal ? size.height : NavMetrics.gripLength)
            .contentShape(Rectangle())
            .gesture(carryGesture(layer: layer, center: center))
            .accessibilityLabel("Move the nav")
    }

    private func itemButton(_ item: NavItem) -> some View {
        let isSelected = item.id == selectedId
        let color = isSelected || item.isTinted ? item.tint : Palette.textBody
        let size = NavMetrics.itemSize(orientation)
        let isTool = groups.first?.contains { $0.id == item.id } ?? false
        let isLifted = toolReordering?.id == item.id
        return HoldableButton(action: {}, onTapAt: { frame in
            guard Date() >= swallowUntil else { return }
            item.action(frame)
        }) {
            ZStack {
                if isSelected {
                    Capsule()
                        .fill(Palette.pressedWash)
                        .matchedGeometryEffect(id: "wash", in: washSpace)
                }
                if let caption = item.caption {
                    Text(caption)
                        .font(Typography.monoBold(15 * NavMetrics.scale))
                        .foregroundColor(color)
                } else {
                    GlyphView(name: item.glyph, color: color, size: NavMetrics.glyphSize)
                        .scaleEffect(isSelected ? 1.06 : 1)
                }
                if let swatch = item.swatch {
                    Circle()
                        .fill(swatch)
                        .frame(width: 6 * NavMetrics.scale, height: 6 * NavMetrics.scale)
                        .overlay(Circle().stroke(Palette.borderControl, lineWidth: 1))
                        .offset(y: 16 * NavMetrics.scale)
                }
            }
            .frame(width: size.width, height: size.height)
        }
        .disabled(!item.isEnabled)
        .opacity(item.isEnabled ? 1 : 0.38)
        .scaleEffect(isLifted ? CGFloat(Motion.scales.held) : 1)
        .offset(x: isLifted && orientation == .horizontal ? toolReordering?.offset ?? 0 : 0, y: isLifted && orientation == .vertical ? toolReordering?.offset ?? 0 : 0)
        .zIndex(isLifted ? 1 : 0)
        .transaction { transaction in
            if isLifted {
                transaction.animation = nil
            }
        }
        .simultaneousGesture(isTool ? toolReorderGesture(item.id) : nil)
        .accessibilityLabel(item.label)
    }

    private var subNavBody: some View {
        let layout = orientation == .horizontal ? AnyLayout(HStackLayout(spacing: NavMetrics.spacing)) : AnyLayout(VStackLayout(spacing: NavMetrics.spacing))
        let shown = isRetracting ? [] : orderedSubNavigationGroups
        return layout {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, group in
                if index > 0 {
                    NavSeparator(orientation: orientation)
                        .transition(.pop)
                }
                subNavigationGroup(group)
                    .transition(.pop)
            }
        }
        .animation(Motion.placement, value: groupReordering?.order)
        .padding(NavMetrics.padding)
        .background(Capsule().fill(Palette.panelSolid))
        .overlay(Capsule().stroke(Palette.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 16, y: 12)
        .fixedSize()
        .animation(Motion.powerThreeInOut(Motion.stateMilliseconds * 2), value: shown.map(\.id))
        .background(GeometryReader { subProxy in Color.clear.preference(key: SubNavSizeKey.self, value: subProxy.size) })
    }

    private func subNavigationGroup(_ group: SubNavigationGroup) -> some View {
        let isLifted = groupReordering?.id == group.id
        let offset = isLifted ? groupReordering?.offset ?? 0 : 0
        return group.content(orientation)
            .background(GeometryReader { groupProxy in Color.clear.preference(key: GroupExtentKey.self, value: [group.id: groupProxy.size]) })
            .scaleEffect(isLifted ? CGFloat(Motion.scales.held) : 1)
            .offset(x: orientation == .horizontal ? offset : 0, y: orientation == .vertical ? offset : 0)
            .zIndex(isLifted ? 1 : 0)
            .transaction { transaction in
                if isLifted {
                    transaction.animation = nil
                }
            }
            .simultaneousGesture(groupReorderGesture(group.id))
    }

    private func axisValue(_ point: CGPoint) -> CGFloat {
        orientation == .horizontal ? point.x : point.y
    }

    private func toolReorderGesture(_ id: String) -> some Gesture {
        LongPressGesture(minimumDuration: Motion.seconds(Motion.menuHoldMilliseconds), maximumDistance: 10)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(NavMetrics.layerSpace)))
            .onChanged { value in
                guard case .second(true, let drag) = value, let drag else { return }
                if toolReordering == nil {
                    swallowUntil = .distantFuture
                    Haptics.hold()
                    toolReordering = Reordering(id: id, order: toolIds, anchor: axisValue(drag.location), offset: 0)
                }
                guard var reordering = toolReordering else { return }
                let extent = NavMetrics.along(NavMetrics.itemSize(orientation), orientation) + NavMetrics.spacing
                reordering.offset = axisValue(drag.location) - reordering.anchor
                stepReordering(&reordering, extentAfter: { _ in extent }, extentBefore: { _ in extent })
                toolReordering = reordering
            }
            .onEnded { _ in
                if let order = toolReordering?.order {
                    onReorderTools(order)
                    Haptics.landed()
                }
                withAnimation(Motion.placement) {
                    toolReordering = nil
                }
                swallowUntil = Date().addingTimeInterval(0.6)
            }
    }

    private func groupReorderGesture(_ id: String) -> some Gesture {
        LongPressGesture(minimumDuration: Motion.seconds(Motion.menuHoldMilliseconds), maximumDistance: 10)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(NavMetrics.layerSpace)))
            .onChanged { value in
                guard case .second(true, let drag) = value, let drag else { return }
                if groupReordering == nil {
                    Haptics.hold()
                    groupReordering = Reordering(id: id, order: subNavigationGroups.map(\.id), anchor: axisValue(drag.location), offset: 0)
                }
                guard var reordering = groupReordering else { return }
                let separator = NavSeparator.extent + NavMetrics.spacing * 2
                let extent: (String) -> CGFloat = { groupId in NavMetrics.along(groupSizes[groupId] ?? .zero, orientation) + separator }
                reordering.offset = axisValue(drag.location) - reordering.anchor
                stepReordering(&reordering, extentAfter: extent, extentBefore: extent)
                groupReordering = reordering
            }
            .onEnded { _ in
                if let order = groupReordering?.order {
                    onReorderSubNavigation(order)
                    Haptics.landed()
                }
                withAnimation(Motion.placement) {
                    groupReordering = nil
                }
            }
    }

    private func stepReordering(_ reordering: inout Reordering, extentAfter: (String) -> CGFloat, extentBefore: (String) -> CGFloat) {
        while let index = reordering.order.firstIndex(of: reordering.id), index < reordering.order.count - 1 {
            let neighbour = reordering.order[index + 1]
            let extent = extentAfter(neighbour)
            guard reordering.offset > extent / 2 else { break }
            reordering.order.swapAt(index, index + 1)
            reordering.anchor += extent
            reordering.offset -= extent
            Haptics.segment()
        }
        while let index = reordering.order.firstIndex(of: reordering.id), index > 0 {
            let neighbour = reordering.order[index - 1]
            let extent = extentBefore(neighbour)
            guard reordering.offset < -extent / 2 else { break }
            reordering.order.swapAt(index, index - 1)
            reordering.anchor -= extent
            reordering.offset += extent
            Haptics.segment()
        }
    }

    private func rect(center: CGPoint, size: CGSize) -> CGRect {
        CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
    }

    private func localObstacles(origin: CGPoint, layer: CGSize) -> [CGRect] {
        var blocked = obstacles.map { $0.offsetBy(dx: -origin.x, dy: -origin.y) }
        if keyboardHeight > 0 {
            blocked.append(CGRect(x: 0, y: layer.height - keyboardHeight, width: layer.width, height: keyboardHeight))
        }
        return blocked
    }

    private func clamped(_ point: CGPoint, size: CGSize, layer: CGSize) -> CGPoint {
        func clamp(_ value: CGFloat, _ half: CGFloat, _ total: CGFloat) -> CGFloat {
            total - NavMetrics.edgeMargin * 2 < half * 2 ? total / 2 : min(total - NavMetrics.edgeMargin - half, max(NavMetrics.edgeMargin + half, value))
        }
        return CGPoint(x: clamp(point.x, size.width / 2, layer.width), y: clamp(point.y, size.height / 2, layer.height))
    }

    private func avoiding(_ center: CGPoint, size: CGSize, layer: CGSize, blocked: [CGRect]) -> CGPoint {
        let start = clamped(center, size: size, layer: layer)
        func isFree(_ point: CGPoint) -> Bool {
            let candidate = rect(center: point, size: size).insetBy(dx: -NavMetrics.avoidGap / 2, dy: -NavMetrics.avoidGap / 2)
            return !blocked.contains { $0.intersects(candidate) }
        }
        guard !isFree(start) else { return start }
        var candidates: [CGPoint] = []
        var frontier = [start]
        for _ in 0..<3 {
            var next: [CGPoint] = []
            for point in frontier {
                let current = rect(center: point, size: size)
                for obstacle in blocked where obstacle.insetBy(dx: -NavMetrics.avoidGap, dy: -NavMetrics.avoidGap).intersects(current) {
                    let gap = NavMetrics.avoidGap
                    next.append(CGPoint(x: point.x, y: obstacle.minY - gap - size.height / 2))
                    next.append(CGPoint(x: point.x, y: obstacle.maxY + gap + size.height / 2))
                    next.append(CGPoint(x: obstacle.minX - gap - size.width / 2, y: point.y))
                    next.append(CGPoint(x: obstacle.maxX + gap + size.width / 2, y: point.y))
                }
            }
            let inside = next.filter { clamped($0, size: size, layer: layer) == $0 }
            candidates.append(contentsOf: inside.filter(isFree))
            frontier = inside
        }
        return candidates.min { hypot($0.x - start.x, $0.y - start.y) < hypot($1.x - start.x, $1.y - start.y) } ?? start
    }

    private func navCenter(in layer: CGSize, blocked: [CGRect]) -> CGPoint {
        if let carryPoint {
            return clamped(carryPoint, size: navSize, layer: layer)
        }
        let wanted: CGPoint
        if let placement {
            wanted = CGPoint(x: placement.x * layer.width, y: placement.y * layer.height)
        } else {
            wanted = CGPoint(x: layer.width / 2, y: layer.height - NavMetrics.bottomGap - navSize.height / 2)
        }
        return avoiding(wanted, size: navSize, layer: layer, blocked: blocked)
    }

    private func outwardSide(center: CGPoint, layer: CGSize) -> NavSide {
        if orientation == .vertical {
            return center.x > layer.width / 2 ? .left : .right
        }
        return center.y > layer.height / 2 ? .up : .down
    }

    private func beside(_ anchor: CGRect, size: CGSize, side: NavSide) -> CGPoint {
        switch side {
        case .up: return CGPoint(x: anchor.midX, y: anchor.minY - NavMetrics.besideGap - size.height / 2)
        case .down: return CGPoint(x: anchor.midX, y: anchor.maxY + NavMetrics.besideGap + size.height / 2)
        case .left: return CGPoint(x: anchor.minX - NavMetrics.besideGap - size.width / 2, y: anchor.midY)
        case .right: return CGPoint(x: anchor.maxX + NavMetrics.besideGap + size.width / 2, y: anchor.midY)
        }
    }

    private func placeBeside(_ anchor: CGRect, size: CGSize, side: NavSide, layer: CGSize, blocked: [CGRect]) -> CGPoint {
        avoiding(beside(anchor, size: size, side: side), size: size, layer: layer, blocked: blocked)
    }

    private func carryGesture(layer: CGSize, center: CGPoint) -> some Gesture {
        LongPressGesture(minimumDuration: Motion.seconds(Motion.navigationGripHoldMilliseconds), maximumDistance: 10)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(NavMetrics.layerSpace)))
            .onChanged { value in
                guard case .second(true, let drag) = value else { return }
                if carryPoint == nil {
                    swallowUntil = .distantFuture
                    Haptics.hold()
                    let start = drag?.startLocation ?? center
                    carryGrab = CGSize(width: start.x - center.x, height: start.y - center.y)
                }
                let location = drag?.location ?? center
                carryPoint = CGPoint(x: location.x - carryGrab.width, y: location.y - carryGrab.height)
            }
            .onEnded { _ in
                guard let point = carryPoint else { return }
                let sideDistance = min(point.x, layer.width - point.x)
                let endDistance = min(point.y, layer.height - point.y)
                let nextOrientation: NavOrientation = sideDistance < endDistance ? .vertical : .horizontal
                let next = NavPlacement(x: Double(point.x / max(1, layer.width)), y: Double(point.y / max(1, layer.height)), orientation: nextOrientation.rawValue)
                Preferences.shared.setNavPlacement(next)
                withAnimation(Motion.powerThreeInOut(Motion.stateMilliseconds * 2)) {
                    orientation = nextOrientation
                    placement = next
                    carryPoint = nil
                }
                swallowUntil = Date().addingTimeInterval(0.6)
            }
    }
}
