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
    var sizing: NavSizing?
    var action: (CGRect) -> Void
}

struct NavSizing {
    let share: Double
    let color: Color
    let previewDiameter: (Double) -> CGFloat
    let caption: (Double) -> String
    let onChange: (Double) -> Void
    var canvasPreview: SizePreview?
}

struct SizePreview {
    let diameter: (Double) -> CGFloat
    let color: Color
    var isRing = false
}

private struct SizePreviewDot: View {
    let preview: SizePreview
    let share: Double

    var body: some View {
        let diameter = max(1, preview.diameter(share))
        ZStack {
            if preview.isRing {
                Circle()
                    .fill(preview.color.opacity(0.12))
                    .overlay(Circle().stroke(preview.color.opacity(0.9), lineWidth: 1.5))
            } else {
                Circle()
                    .fill(preview.color)
            }
        }
        .frame(width: diameter, height: diameter)
    }
}

struct SubNavigationGroup: Identifiable {
    let id: String
    let content: (NavOrientation) -> AnyView
    var onCollapse: ((Bool) -> Bool)?
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

struct NavCoverKey: PreferenceKey {
    static var defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
        value.append(contentsOf: nextValue())
    }
}

private struct GroupExtentKey: PreferenceKey {
    static var defaultValue: [String: CGSize] = [:]
    static func reduce(value: inout [String: CGSize], nextValue: () -> [String: CGSize]) {
        value.merge(nextValue()) { _, next in next }
    }
}

enum NavMetrics {
    static let scale: CGFloat = 1
    static let edgeMargin: CGFloat = 16
    static let bottomGap: CGFloat = 24
    static let besideGap: CGFloat = 10
    static let avoidGap: CGFloat = 12
    static let padding: CGFloat = 5 * scale
    static let spacing: CGFloat = 2 * scale
    static let glyphSize: CGFloat = 22 * scale
    static let gripLength: CGFloat = 18 * scale
    static let sizingSlop: CGFloat = 6
    static let navSizingSlop: CGFloat = 22
    static let navSizingDominance: CGFloat = 2
    static let shadowReach: CGFloat = 32
    static let edgeStripDepth: CGFloat = 28
    static let edgeTouchReach: CGFloat = 4
    static let edgeHandleSize = CGSize(width: 36, height: 4)
    static let bubbleDiameter = CGFloat(Motion.carry.bubbleDiameter)
    static let pillPanelPrefix = "variations-"
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
    let start: [String]
    var order: [String]
    let anchor: CGFloat
    var drag: CGFloat

    func positions(_ ids: [String], extent: (String) -> CGFloat) -> [String: CGFloat] {
        var result: [String: CGFloat] = [:]
        var position: CGFloat = 0
        for id in ids {
            result[id] = position
            position += extent(id)
        }
        return result
    }

    func shift(_ itemId: String, extent: (String) -> CGFloat) -> CGFloat {
        (positions(order, extent: extent)[itemId] ?? 0) - (positions(start, extent: extent)[itemId] ?? 0)
    }

    func offset(_ itemId: String, extent: (String) -> CGFloat) -> CGFloat {
        itemId == id ? drag : shift(itemId, extent: extent)
    }
}

private struct Settling {
    let id: String
    var offset: CGFloat
}

private struct SizingDrag {
    let id: String
    let startShare: Double
    let startTranslation: CGFloat
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
    @ViewBuilder var panel: (String, NavOrientation) -> PanelContent

    @Namespace private var washSpace
    @StateObject private var navigationMotion = PillMotion()
    @StateObject private var subNavigationMotion = PillMotion()
    @StateObject private var panelMotion = PillMotion()
    @State private var shownPillPanelKey: String?
    @State private var edgeOffset: CGFloat = 0
    @State private var edgeDragStart: CGFloat?
    @State private var isEdgeHidden = false
    @State private var orientation: NavOrientation = Preferences.shared.navPlacement?.orientation == NavOrientation.vertical.rawValue ? .vertical : .horizontal
    @State private var navSize: CGSize = .zero
    @State private var subNavSize: CGSize = .zero
    @State private var panelSize: CGSize = .zero
    @State private var groupSizes: [String: CGSize] = [:]
    @StateObject private var carry = NavCarry(placement: Preferences.shared.navPlacement)
    @State private var turningOrientation: NavOrientation?
    @State private var turnEndsAt: Double = 0
    @State private var carryOrigin: CGPoint = .zero
    @State private var panelAnchor: CGRect?
    @State private var swallowUntil = Date.distantPast
    @State private var shownSubNavigationKey: String?
    @State private var toolReordering: Reordering?
    @State private var groupReordering: Reordering?
    @State private var toolSettling: Settling?
    @State private var groupSettling: Settling?
    @State private var sizingDrag: SizingDrag?
    @State private var isSizingRejected = false
    @State private var isCollapseSwiped = false
    @State private var isCollapseSwipeRejected = false
    @State private var carryLayer: CGSize = .zero
    @State private var isPresetPressed = false
    @State private var isPresetLifted = false
    @GestureState private var isEdgeGestureActive = false
    @GestureState private var isCollapseGestureActive = false
    @GestureState private var isSizingGestureActive = false
    @GestureState private var isToolGestureActive = false
    @GestureState private var isGroupGestureActive = false
    @GestureState private var isCarryGestureActive = false

    private var isNavigationGestureActive: Bool {
        isEdgeGestureActive || isCollapseGestureActive || isSizingGestureActive || isToolGestureActive || isGroupGestureActive || isCarryGestureActive
    }

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
        toolReordering?.start ?? groups.first?.map(\.id) ?? []
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
        guard let order = groupReordering?.start else { return subNavigationGroups }
        return order.compactMap { id in subNavigationGroups.first { $0.id == id } }
    }

    private var isSubNavigationWanted: Bool {
        subNavKey != nil && isShown && !carry.isStageCleared
    }

    private var wantedPillPanelKey: String? {
        guard isSubNavigationWanted, let panelKey, panelKey.hasPrefix(NavMetrics.pillPanelPrefix) else { return nil }
        return panelKey
    }

    private var wheelPanelKey: String? {
        guard isSubNavigationWanted, let panelKey, !panelKey.hasPrefix(NavMetrics.pillPanelPrefix) else { return nil }
        return panelKey
    }

    private var sizingItem: NavItem? {
        guard let sizingDrag else { return nil }
        return groups.joined().first { $0.id == sizingDrag.id }
    }

    private var sizableItem: NavItem? {
        let items = Array(groups.joined())
        if let selectedId {
            return items.first { $0.id == selectedId && $0.sizing != nil }
        }
        return items.first { $0.sizing != nil }
    }

    private var toolExtent: CGFloat {
        NavMetrics.along(NavMetrics.itemSize(orientation), orientation) + NavMetrics.spacing
    }

    private func groupExtent(_ id: String) -> CGFloat {
        NavMetrics.along(groupSizes[id] ?? .zero, orientation) + NavSeparator.extent + NavMetrics.spacing * 2
    }

    var body: some View {
        GeometryReader { proxy in
            let layer = proxy.size
            let layerOrigin = proxy.frame(in: .global).origin
            let blocked = localObstacles(origin: layerOrigin, layer: layer)
            let center = navCenter(in: layer, blocked: blocked)
            let navigationRect = rect(center: center, size: navSize)
            let side = outwardSide(center: center, layer: layer)
            let edge = edgeSide(of: side)
            let hiddenReach = hiddenDistance(center: center, layer: layer, edge: edge)
            let subNavCenter = placeBeside(navigationRect, size: subNavSize, side: side, layer: layer, blocked: blocked + [navigationRect])
            let subNavRect = rect(center: subNavCenter, size: subNavSize)
            let panelCenter = placeBeside(panelAnchor ?? subNavRect, size: panelSize, side: side, layer: layer, blocked: blocked + [navigationRect, subNavRect])
            let edgeShare = hiddenReach > 0 ? edgeOffset / hiddenReach : 0
            ZStack(alignment: .topLeading) {
                ZStack {
                    if shownSubNavigationKey != nil {
                        subNavBody
                    }
                }
                .simultaneousGesture(edgeHideGesture(edge: edge, limit: hiddenReach, follow: subNavFollow(subNavCenter: subNavCenter, center: center, edge: edge, limit: hiddenReach)))
                .position(subNavCenter)
                .offset(stackFollow(from: subNavCenter, to: center, share: edgeShare))
                ZStack {
                    if let key = wheelPanelKey {
                        panel(key, orientation)
                            .fixedSize()
                            .background(GeometryReader { panelProxy in Color.clear.preference(key: PanelSizeKey.self, value: panelProxy.size) })
                            .id(key)
                            .transition(.popTogether)
                    }
                    if let key = shownPillPanelKey {
                        pillPanelBody(key)
                    }
                }
                .position(panelCenter)
                .animation(shownPillPanelKey != nil && panelMotion.areElementsShown ? Motion.placement : nil, value: panelCenter)
                .offset(stackFollow(from: panelCenter, to: subNavCenter, share: edgeShare))
                ZStack {
                    if let sizing = sizingItem?.sizing, let preview = sizing.canvasPreview {
                        SizePreviewDot(preview: preview, share: sizing.share)
                            .transition(.sliderEnter)
                    }
                }
                .position(x: layer.width / 2, y: layer.height / 2)
                .allowsHitTesting(false)
                navBody(layer: layer, center: center)
                    .simultaneousGesture(edgeHideGesture(edge: edge, limit: hiddenReach))
                    .position(center)
                    .offset(edgeVector(edge, edgeOffset))
                ZStack {
                    if isEdgeHidden {
                        edgeStrip(edge: edge, limit: hiddenReach)
                            .transition(.popTogether)
                    }
                }
                .position(edgeStripCenter(center: center, layer: layer, edge: edge))
            }
            .animation(!carry.isActive && navigationMotion.areElementsShown ? Motion.placement : nil, value: center)
            .animation(!carry.isActive && navigationMotion.areElementsShown ? Motion.placement : nil, value: subNavCenter)
            .coordinateSpace(name: NavMetrics.layerSpace)
            .preference(key: NavCoverKey.self, value: covers(navigation: navigationRect.offsetBy(dx: edgeVector(edge, edgeOffset).width, dy: edgeVector(edge, edgeOffset).height), subNavigation: subNavRect, panel: rect(center: panelCenter, size: panelSize)).map { $0.offsetBy(dx: layerOrigin.x, dy: layerOrigin.y) })
            .onPreferenceChange(NavSizeKey.self) { navSize = $0 }
            .onPreferenceChange(SubNavSizeKey.self) { subNavSize = $0 }
            .onPreferenceChange(PanelSizeKey.self) { panelSize = $0 }
            .onPreferenceChange(GroupExtentKey.self) { groupSizes = $0 }
            .onAppear {
                carryLayer = layer
                carryOrigin = layerOrigin
                connectCarry()
                carry.restore(corner: carry.placement?.corner)
            }
            .onChange(of: layer) { _, size in carryLayer = size }
            .onChange(of: layerOrigin) { _, origin in carryOrigin = origin }
            .onPreferenceChange(PanelAnchorKey.self) { anchor in
                if anchor != nil || shownPillPanelKey == nil {
                    panelAnchor = anchor
                }
            }
        }
        .onAppear {
            if isShown {
                navigationMotion.enter()
            }
            if isSubNavigationWanted {
                openSubNavigation()
            }
        }
        .onChange(of: obstacles) { _, _ in connectCarry() }
        .onChange(of: keyboardHeight) { _, _ in connectCarry() }
        .onChange(of: isShown) { _, shown in
            recoverGestures()
            if shown {
                navigationMotion.enter()
            } else {
                navigationMotion.leave()
            }
        }
        .onChange(of: isNavigationGestureActive) { _, isActive in
            guard !isActive else { return }
            DispatchQueue.main.async {
                recoverGestures()
            }
        }
        .onChange(of: isSubNavigationWanted) { _, isWanted in
            if isWanted {
                openSubNavigation()
            } else {
                closeSubNavigation()
            }
        }
        .onChange(of: subNavKey) { _, key in
            if key != nil, isSubNavigationWanted {
                shownSubNavigationKey = key
            }
        }
        .onChange(of: wantedPillPanelKey) { _, key in
            if let key {
                let isEntering = shownPillPanelKey == nil || !panelMotion.areElementsShown
                shownPillPanelKey = key
                if isEntering {
                    panelMotion.enter()
                }
            } else if shownPillPanelKey != nil {
                panelMotion.leave {
                    shownPillPanelKey = nil
                }
            }
        }
        .onChange(of: shownSubNavigationKey) { _, key in
            if key == nil, isEdgeHidden {
                showFromEdge()
            }
        }
    }

    private func pillPanelBody(_ key: String) -> some View {
        panel(key, orientation)
            .environment(\.isElementRevealed, panelMotion.areElementsShown)
            .padding(NavMetrics.padding)
            .fixedSize()
            .background(GeometryReader { panelProxy in Color.clear.preference(key: PanelSizeKey.self, value: panelProxy.size) })
            .background(PillShell(scale: panelMotion.shellScale, spread: panelMotion.shellSpread, isWide: orientation == .horizontal))
            .allowsHitTesting(panelMotion.areElementsShown)
    }

    private func covers(navigation: CGRect, subNavigation: CGRect, panel: CGRect) -> [CGRect] {
        var covers: [CGRect] = []
        if navigationMotion.isPresent {
            let lift = carry.state == .carried ? CGFloat(Motion.scales.held) : 1
            let shown = shownSize(carry.morph)
            let body = CGRect(x: navigation.midX - shown.width / 2, y: navigation.midY - shown.height / 2, width: shown.width, height: shown.height)
            covers.append(body.insetBy(dx: body.width * (1 - lift) / 2, dy: body.height * (1 - lift) / 2))
        }
        if shownSubNavigationKey != nil {
            covers.append(subNavigation)
        }
        if wheelPanelKey != nil || shownPillPanelKey != nil {
            covers.append(panel)
        }
        return covers
    }

    private func edgeSide(of outward: NavSide) -> NavSide {
        switch outward {
        case .up: return .down
        case .down: return .up
        case .left: return .right
        case .right: return .left
        }
    }

    private func stackFollow(from start: CGPoint, to end: CGPoint, share: CGFloat) -> CGSize {
        CGSize(width: (end.x - start.x) * share, height: (end.y - start.y) * share)
    }

    private func edgeVector(_ edge: NavSide, _ distance: CGFloat) -> CGSize {
        switch edge {
        case .up: return CGSize(width: 0, height: -distance)
        case .down: return CGSize(width: 0, height: distance)
        case .left: return CGSize(width: -distance, height: 0)
        case .right: return CGSize(width: distance, height: 0)
        }
    }

    private func outwardTravel(_ translation: CGSize, _ edge: NavSide) -> (outward: CGFloat, across: CGFloat) {
        switch edge {
        case .up: return (-translation.height, translation.width)
        case .down: return (translation.height, translation.width)
        case .left: return (-translation.width, translation.height)
        case .right: return (translation.width, translation.height)
        }
    }

    private func crossExtent(_ edge: NavSide) -> CGFloat {
        edge == .up || edge == .down ? navSize.height : navSize.width
    }

    private func hiddenDistance(center: CGPoint, layer: CGSize, edge: NavSide) -> CGFloat {
        switch edge {
        case .up: return center.y + navSize.height / 2 + NavMetrics.shadowReach
        case .down: return layer.height - center.y + navSize.height / 2 + NavMetrics.shadowReach
        case .left: return center.x + navSize.width / 2 + NavMetrics.shadowReach
        case .right: return layer.width - center.x + navSize.width / 2 + NavMetrics.shadowReach
        }
    }

    private func rubberBanded(_ distance: CGFloat, limit: CGFloat) -> CGFloat {
        let rubber = CGFloat(Motion.shares.navEdgeRubber)
        if distance < 0 {
            return distance * rubber
        }
        if distance > limit {
            return limit + (distance - limit) * rubber
        }
        return distance
    }

    private func recoverGestures() {
        guard !isNavigationGestureActive else { return }
        if edgeDragStart != nil {
            edgeDragStart = nil
            if !isEdgeHidden {
                withAnimation(Motion.backOut(Motion.navigationEdgeHideMilliseconds)) {
                    edgeOffset = 0
                }
            }
        }
        isCollapseSwiped = false
        isCollapseSwipeRejected = false
        isSizingRejected = false
        if sizingDrag != nil {
            sizingDrag = nil
        }
        finishToolReordering()
        finishGroupReordering()
        if carry.state == .carried {
            carry.release()
        }
        if swallowUntil == .distantFuture {
            swallowUntil = Date().addingTimeInterval(0.6)
        }
    }

    private func subNavFollow(subNavCenter: CGPoint, center: CGPoint, edge: NavSide, limit: CGFloat) -> CGFloat {
        let isAcross = edge == .up || edge == .down
        let distance = abs(isAcross ? subNavCenter.y - center.y : subNavCenter.x - center.x)
        return limit / max(1, distance)
    }

    private func edgeHideGesture(edge: NavSide, limit: CGFloat, follow: CGFloat = 1) -> some Gesture {
        DragGesture(minimumDistance: NavMetrics.navSizingSlop, coordinateSpace: .named(NavMetrics.layerSpace))
            .updating($isEdgeGestureActive) { _, isActive, _ in isActive = true }
            .onChanged { value in
                guard sizingDrag == nil, toolReordering == nil, groupReordering == nil, !isPresetLifted, !carry.isStageCleared, !isEdgeHidden else { return }
                let travel = outwardTravel(value.translation, edge)
                if edgeDragStart == nil {
                    guard shownSubNavigationKey != nil, abs(travel.outward) > abs(travel.across) * NavMetrics.navSizingDominance else { return }
                    swallowUntil = .distantFuture
                    Haptics.tick()
                    edgeDragStart = travel.outward
                }
                guard let start = edgeDragStart else { return }
                edgeOffset = rubberBanded((travel.outward - start) * follow, limit: limit)
            }
            .onEnded { _ in
                guard edgeDragStart != nil else { return }
                edgeDragStart = nil
                swallowUntil = Date().addingTimeInterval(0.6)
                if edgeOffset > crossExtent(edge) * CGFloat(Motion.shares.navEdgeHide) {
                    Haptics.landed()
                    withAnimation(Motion.powerTwoIn(Motion.navigationEdgeHideMilliseconds * 2 / 3)) {
                        edgeOffset = limit
                        isEdgeHidden = true
                    }
                } else {
                    withAnimation(Motion.backOut(Motion.navigationEdgeHideMilliseconds)) {
                        edgeOffset = 0
                    }
                }
            }
    }

    private func showFromEdge() {
        Haptics.landed()
        withAnimation(Motion.backOut(Motion.navigationEdgeHideMilliseconds)) {
            edgeOffset = 0
            isEdgeHidden = false
        }
    }

    private func edgeStripCenter(center: CGPoint, layer: CGSize, edge: NavSide) -> CGPoint {
        let half = NavMetrics.edgeStripDepth / 2
        switch edge {
        case .up: return CGPoint(x: center.x, y: half)
        case .down: return CGPoint(x: center.x, y: layer.height - half)
        case .left: return CGPoint(x: half, y: center.y)
        case .right: return CGPoint(x: layer.width - half, y: center.y)
        }
    }

    private func edgeStrip(edge: NavSide, limit: CGFloat) -> some View {
        let isAcross = edge == .up || edge == .down
        let handle = NavMetrics.edgeHandleSize
        return Capsule()
            .fill(Palette.borderHover)
            .frame(width: isAcross ? handle.width : handle.height, height: isAcross ? handle.height : handle.width)
            .frame(width: isAcross ? max(navSize.width, handle.width) : NavMetrics.edgeStripDepth, height: isAcross ? NavMetrics.edgeStripDepth : max(navSize.height, handle.width))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .named(NavMetrics.layerSpace))
                    .onChanged { value in
                        let inward = -outwardTravel(value.translation, edge).outward
                        edgeOffset = limit - rubberBanded(inward, limit: limit)
                    }
                    .onEnded { _ in
                        if limit - edgeOffset > crossExtent(edge) * CGFloat(Motion.shares.navEdgeHide) {
                            showFromEdge()
                        } else {
                            withAnimation(Motion.powerTwoIn(Motion.navigationEdgeHideMilliseconds * 2 / 3)) {
                                edgeOffset = limit
                            }
                        }
                    }
            )
            .accessibilityLabel("Show the nav")
            .accessibilityAction { showFromEdge() }
    }

    private func openSubNavigation() {
        shownSubNavigationKey = subNavKey
        subNavigationMotion.enter()
    }

    private func closeSubNavigation() {
        guard shownSubNavigationKey != nil else { return }
        subNavigationMotion.leave(keepsShape: true) {
            shownSubNavigationKey = nil
        }
    }

    private func navBody(layer: CGSize, center: CGPoint) -> some View {
        let layout = orientation == .horizontal ? AnyLayout(HStackLayout(spacing: NavMetrics.spacing)) : AnyLayout(VStackLayout(spacing: NavMetrics.spacing))
        let isSizing = sizingDrag != nil
        let isBubble = carry.morph >= 0.5
        let contentShare: CGFloat = min(1, max(0, 1 - carry.morph * 2))
        let bubbleShare: CGFloat = NavMetrics.bubbleDiameter / max(1, max(navSize.width, navSize.height))
        return layout {
            grip(layer: layer, center: center)
                .revealedElement()
            ForEach(entries) { entry in
                switch entry {
                case .item(let item):
                    itemButton(item)
                        .revealedElement()
                        .transition(.elementLeave)
                case .separator:
                    NavSeparator(orientation: orientation)
                        .revealedElement()
                        .transition(.elementLeave)
                }
            }
            grip(layer: layer, center: center)
                .revealedElement()
        }
        .environment(\.isElementRevealed, navigationMotion.areElementsShown)
        .environment(\.isElementMutating, navigationMotion.isMutating)
        .opacity(isSizing ? 0 : 1)
        .scaleEffect(isSizing ? CGFloat(Motion.scales.sliderEnter) : 1)
        .animation(isSizing ? Motion.powerTwoIn(Motion.pressMilliseconds) : Motion.powerTwoOut(Motion.stateMilliseconds, delay: Motion.pressMilliseconds), value: isSizing)
        .overlay {
            ZStack {
                if let item = sizingItem, let sizing = item.sizing {
                    NavSizeSlider(orientation: orientation, share: sizing.share, color: sizing.color, previewDiameter: sizing.previewDiameter(sizing.share), startThickness: sizing.previewDiameter(0), endThickness: sizing.previewDiameter(1), caption: sizing.caption(sizing.share))
                        .transition(.sliderEnter)
                }
            }
        }
        .animation(Motion.wash, value: selectedId)
        .padding(NavMetrics.padding)
        .opacity(contentShare)
        .scaleEffect(1 - (1 - bubbleShare) * min(CGFloat(1), carry.morph))
        .background(PillShell(scale: navigationMotion.shellScale, spread: navigationMotion.shellSpread, isWide: orientation == .horizontal, stroke: carry.state == .carried ? Palette.accent : Palette.border, morph: carry.morph, bubbleDiameter: NavMetrics.bubbleDiameter, stretchAmount: carry.stretchAmount, stretchAngle: carry.stretchAngle))
        .contentShape(Capsule())
        .simultaneousGesture(sizableItem == nil ? nil : sizingGesture())
        .allowsHitTesting(!isBubble && !carry.isActive)
        .overlay(alignment: grabberAlignment(center: center, layer: layer)) {
            grabber(center: center)
        }
        .overlay {
            bubbleFace(center: center)
        }
        .fixedSize()
        .background(GeometryReader { navProxy in Color.clear.preference(key: NavSizeKey.self, value: navProxy.size) })
        .scaleEffect(carry.state == .carried ? CGFloat(Motion.scales.held) : 1)
        .allowsHitTesting(navigationMotion.areElementsShown || carry.isStageCleared)
        .animation(Motion.powerThreeInOut(Motion.navigationSwitchMilliseconds * 2), value: face)
        .animation(Motion.backOut(Motion.stateMilliseconds), value: carry.state == .carried)
    }

    private func grip(layer: CGSize, center: CGPoint) -> some View {
        let size = NavMetrics.itemSize(orientation)
        return Color.clear
            .frame(width: orientation == .horizontal ? NavMetrics.gripLength : size.width, height: orientation == .horizontal ? size.height : NavMetrics.gripLength)
            .contentShape(Rectangle())
            .gesture(carryGesture(center: center, waitsForTravel: false))
            .accessibilityLabel("Move the nav")
    }

    private func toolOffset(_ id: String) -> CGFloat {
        if let toolSettling, toolSettling.id == id {
            return toolSettling.offset
        }
        return toolReordering?.offset(id) { _ in toolExtent } ?? 0
    }

    private func itemButton(_ item: NavItem) -> some View {
        let isSelected = item.id == selectedId
        let color = isSelected || item.isTinted ? item.tint : Palette.textBody
        let size = NavMetrics.itemSize(orientation)
        let isTool = groups.first?.contains { $0.id == item.id } ?? false
        let isLifted = toolReordering?.id == item.id
        let offset = isTool ? toolOffset(item.id) : 0
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
        .offset(x: orientation == .horizontal ? offset : 0, y: orientation == .vertical ? offset : 0)
        .zIndex(isLifted || toolSettling?.id == item.id ? 1 : 0)
        .animation(isLifted ? nil : Motion.placement, value: offset)
        .simultaneousGesture(isTool ? toolReorderGesture(item.id) : nil)
        .accessibilityLabel(item.label)
    }

    private var subNavBody: some View {
        let layout = orientation == .horizontal ? AnyLayout(HStackLayout(spacing: NavMetrics.spacing)) : AnyLayout(VStackLayout(spacing: NavMetrics.spacing))
        let shown = orderedSubNavigationGroups
        return layout {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, group in
                if index > 0 {
                    NavSeparator(orientation: orientation)
                        .revealedElement()
                        .transition(.elementLeave)
                }
                subNavigationGroup(group)
                    .transition(.groupLeave)
            }
        }
        .environment(\.isElementRevealed, subNavigationMotion.areElementsShown)
        .environment(\.navigationTapsResumeAt, swallowUntil)
        .environment(\.presetLiftCallbacks, PresetLiftCallbacks(pressed: { isPresetPressed = $0 }, lifted: { isPresetLifted = $0 }))
        .padding(NavMetrics.padding)
        .fixedSize()
        .animation(Motion.powerThreeInOut(Motion.navigationSwitchMilliseconds * 2), value: shown.map(\.id))
        .background(GeometryReader { subProxy in Color.clear.preference(key: SubNavSizeKey.self, value: subProxy.size) })
        .background(PillShell(scale: subNavigationMotion.shellScale, spread: subNavigationMotion.shellSpread, isWide: orientation == .horizontal))
    }

    private func groupOffset(_ id: String) -> CGFloat {
        if let groupSettling, groupSettling.id == id {
            return groupSettling.offset
        }
        return groupReordering?.offset(id, extent: groupExtent) ?? 0
    }

    private func subNavigationGroup(_ group: SubNavigationGroup) -> some View {
        let isLifted = groupReordering?.id == group.id
        let offset = groupOffset(group.id)
        return group.content(orientation)
            .background(GeometryReader { groupProxy in Color.clear.preference(key: GroupExtentKey.self, value: [group.id: groupProxy.size]) })
            .scaleEffect(isLifted ? CGFloat(Motion.scales.held) : 1)
            .offset(x: orientation == .horizontal ? offset : 0, y: orientation == .vertical ? offset : 0)
            .zIndex(isLifted || groupSettling?.id == group.id ? 1 : 0)
            .animation(isLifted ? nil : Motion.placement, value: offset)
            .simultaneousGesture(groupReorderGesture(group.id))
            .simultaneousGesture(group.onCollapse.map { collapseGesture($0) })
    }

    private func collapseGesture(_ onCollapse: @escaping (Bool) -> Bool) -> some Gesture {
        DragGesture(minimumDistance: NavMetrics.navSizingSlop, coordinateSpace: .named(NavMetrics.layerSpace))
            .updating($isCollapseGestureActive) { _, isActive, _ in isActive = true }
            .onChanged { value in
                guard !isCollapseSwiped, !isCollapseSwipeRejected, groupReordering == nil, !isPresetLifted, !carry.isStageCleared else { return }
                let along = orientation == .horizontal ? value.translation.width : value.translation.height
                let across = orientation == .horizontal ? value.translation.height : value.translation.width
                guard abs(along) > abs(across) * NavMetrics.navSizingDominance else {
                    isCollapseSwipeRejected = true
                    return
                }
                isCollapseSwiped = true
                guard onCollapse(along < 0) else { return }
                swallowUntil = .distantFuture
                Haptics.tick()
            }
            .onEnded { _ in
                isCollapseSwipeRejected = false
                guard isCollapseSwiped else { return }
                isCollapseSwiped = false
                if swallowUntil == .distantFuture {
                    swallowUntil = Date().addingTimeInterval(0.6)
                }
            }
    }

    private func axisValue(_ point: CGPoint) -> CGFloat {
        orientation == .horizontal ? point.x : point.y
    }

    private func sizingGesture() -> some Gesture {
        DragGesture(minimumDistance: NavMetrics.navSizingSlop, coordinateSpace: .named(NavMetrics.layerSpace))
            .updating($isSizingGestureActive) { _, isActive, _ in isActive = true }
            .onChanged { value in
                guard !isSizingRejected, toolReordering == nil, !carry.isStageCleared, let item = sizingItem ?? sizableItem, let sizing = item.sizing else { return }
                let along = orientation == .horizontal ? value.translation.width : -value.translation.height
                if sizingDrag == nil {
                    let across = orientation == .horizontal ? value.translation.height : value.translation.width
                    guard abs(along) > abs(across) * NavMetrics.navSizingDominance else {
                        isSizingRejected = true
                        return
                    }
                    swallowUntil = .distantFuture
                    Haptics.tick()
                    sizingDrag = SizingDrag(id: item.id, startShare: sizing.share, startTranslation: along)
                }
                guard let sizingDrag else { return }
                let delta = along - sizingDrag.startTranslation
                let travel = max(1, NavMetrics.along(navSize, orientation) - NavMetrics.padding * 2 - NavSizeSlider.knob)
                sizing.onChange(min(1, max(0, sizingDrag.startShare + Double(delta / travel))))
            }
            .onEnded { _ in
                isSizingRejected = false
                guard sizingDrag != nil else { return }
                Haptics.landed()
                sizingDrag = nil
                swallowUntil = Date().addingTimeInterval(0.6)
            }
    }

    private func toolReorderGesture(_ id: String) -> some Gesture {
        LongPressGesture(minimumDuration: Motion.seconds(Motion.menuHoldMilliseconds), maximumDistance: 10)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(NavMetrics.layerSpace)))
            .updating($isToolGestureActive) { _, isActive, _ in isActive = true }
            .onChanged { value in
                guard case .second(true, let drag) = value, let drag, sizingDrag == nil else { return }
                if toolReordering == nil {
                    swallowUntil = .distantFuture
                    Haptics.hold()
                    toolReordering = Reordering(id: id, start: toolIds, order: toolIds, anchor: axisValue(drag.location), drag: 0)
                }
                guard var reordering = toolReordering else { return }
                reordering.drag = axisValue(drag.location) - reordering.anchor
                stepReordering(&reordering) { _ in toolExtent }
                toolReordering = reordering
            }
            .onEnded { _ in finishToolReordering() }
    }

    private func finishToolReordering() {
        guard let reordering = toolReordering else { return }
        let residual = reordering.drag - reordering.shift(reordering.id) { _ in toolExtent }
        settle(id: reordering.id, residual: residual, isTool: true) {
            onReorderTools(reordering.order)
        }
        swallowUntil = Date().addingTimeInterval(0.6)
    }

    private func finishGroupReordering() {
        guard let reordering = groupReordering else { return }
        let residual = reordering.drag - reordering.shift(reordering.id, extent: groupExtent)
        settle(id: reordering.id, residual: residual, isTool: false) {
            onReorderSubNavigation(reordering.order)
        }
    }

    private func groupReorderGesture(_ id: String) -> some Gesture {
        LongPressGesture(minimumDuration: Motion.seconds(Motion.menuHoldMilliseconds), maximumDistance: 10)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(NavMetrics.layerSpace)))
            .updating($isGroupGestureActive) { _, isActive, _ in isActive = true }
            .onChanged { value in
                guard case .second(true, let drag) = value, let drag else { return }
                if groupReordering == nil {
                    guard !isPresetPressed, !isPresetLifted, edgeDragStart == nil else { return }
                    Haptics.hold()
                    let order = subNavigationGroups.map(\.id)
                    groupReordering = Reordering(id: id, start: order, order: order, anchor: axisValue(drag.location), drag: 0)
                }
                guard var reordering = groupReordering else { return }
                reordering.drag = axisValue(drag.location) - reordering.anchor
                stepReordering(&reordering, extent: groupExtent)
                groupReordering = reordering
            }
            .onEnded { _ in finishGroupReordering() }
    }

    private func settle(id: String, residual: CGFloat, isTool: Bool, commit: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            commit()
            if isTool {
                toolReordering = nil
                toolSettling = Settling(id: id, offset: residual)
            } else {
                groupReordering = nil
                groupSettling = Settling(id: id, offset: residual)
            }
        }
        Haptics.landed()
        DispatchQueue.main.async {
            withAnimation(Motion.placement) {
                if isTool {
                    toolSettling?.offset = 0
                } else {
                    groupSettling?.offset = 0
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Motion.seconds(Motion.stateMilliseconds * 2)) {
                if isTool {
                    toolSettling = nil
                } else {
                    groupSettling = nil
                }
            }
        }
    }

    private func stepReordering(_ reordering: inout Reordering, extent: (String) -> CGFloat) {
        func relative(_ reordering: Reordering) -> CGFloat {
            reordering.drag - reordering.shift(reordering.id, extent: extent)
        }
        while let index = reordering.order.firstIndex(of: reordering.id), index < reordering.order.count - 1 {
            let neighbour = reordering.order[index + 1]
            guard relative(reordering) > extent(neighbour) / 2 else { break }
            reordering.order.swapAt(index, index + 1)
            Haptics.segment()
        }
        while let index = reordering.order.firstIndex(of: reordering.id), index > 0 {
            let neighbour = reordering.order[index - 1]
            guard relative(reordering) < -extent(neighbour) / 2 else { break }
            reordering.order.swapAt(index, index - 1)
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
        if carry.isActive, let point = carry.center {
            return point
        }
        if carry.state == .parked, let corner = carry.placement?.corner {
            return cornerSpot(corner, layer: layer, blocked: blocked)
        }
        let wanted: CGPoint
        if let placement = carry.placement {
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

    private func connectCarry() {
        carry.host = NavCarryHost(
            bounds: { carryLayer },
            orientation: { orientation },
            shownSize: { shownSize($0) },
            clamped: { clamped($0, size: $1, layer: carryLayer) },
            turnTo: { turnTo($0, isInstant: $1) },
            dockSpot: { dockSpot($0, from: $1) },
            cornerSpot: { cornerSpot($0, layer: carryLayer, blocked: localObstacles(origin: carryOrigin, layer: carryLayer)) },
            onLand: { land(corner: $0) }
        )
    }

    private func shownSize(_ morph: CGFloat) -> CGSize {
        CGSize(width: navSize.width + (NavMetrics.bubbleDiameter - navSize.width) * morph, height: navSize.height + (NavMetrics.bubbleDiameter - navSize.height) * morph)
    }

    private func dockSpot(_ edge: NavEdge?, from point: CGPoint) -> CGPoint {
        let layer = carryLayer
        let margin = NavMetrics.edgeMargin
        var spot = point
        switch edge {
        case .left: spot.x = margin + navSize.width / 2
        case .right: spot.x = layer.width - margin - navSize.width / 2
        case .top: spot.y = margin + navSize.height / 2
        case .bottom: spot.y = layer.height - margin - navSize.height / 2
        case nil: break
        }
        return avoiding(spot, size: navSize, layer: layer, blocked: localObstacles(origin: carryOrigin, layer: layer))
    }

    private func cornerSpot(_ corner: String, layer: CGSize, blocked: [CGRect]) -> CGPoint {
        let diameter = NavMetrics.bubbleDiameter
        let reach = NavMetrics.edgeMargin + diameter / 2
        let parts = corner.split(separator: "-")
        let point = CGPoint(x: parts.last == "left" ? reach : layer.width - reach, y: parts.first == "top" ? reach : layer.height - reach)
        return avoiding(point, size: CGSize(width: diameter, height: diameter), layer: layer, blocked: blocked)
    }

    private func turnCarried() {
        guard let wanted = turningOrientation else { return }
        turningOrientation = nil
        guard wanted != orientation else { return }
        carry.swapGrab()
        withAnimation(Motion.powerThreeInOut(Motion.navigationSwitchMilliseconds * 2)) {
            orientation = wanted
        }
    }

    private func turnTo(_ wanted: NavOrientation, isInstant: Bool) -> Double {
        let now = CACurrentMediaTime() * 1000
        if turningOrientation != nil {
            turningOrientation = wanted
            return max(0, turnEndsAt - now)
        }
        guard wanted != orientation else { return 0 }
        if isInstant {
            carry.swapGrab()
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                orientation = wanted
            }
            return 0
        }
        let changeAt = Double(Motion.navigationMutateLeaveMilliseconds) * 3 / 2
        let total = changeAt + Double(Motion.navigationSwitchMilliseconds * 2)
        turningOrientation = wanted
        turnEndsAt = now + total
        Haptics.tick()
        navigationMotion.mutate(turnCarried)
        return total
    }

    private func land(corner: String?) {
        guard let point = carry.center else { return }
        let layer = carryLayer
        let next = NavPlacement(x: Double(point.x / max(1, layer.width)), y: Double(point.y / max(1, layer.height)), orientation: orientation.rawValue, corner: corner)
        Preferences.shared.setNavPlacement(next)
        carry.place(next)
        swallowUntil = Date().addingTimeInterval(0.6)
        Haptics.landed()
    }

    private func grabberAlignment(center: CGPoint, layer: CGSize) -> Alignment {
        guard orientation == .vertical else { return center.y > layer.height / 2 ? .top : .bottom }
        return center.x > layer.width / 2 ? .leading : .trailing
    }

    private func grabber(center: CGPoint) -> some View {
        let isVertical = orientation == .vertical
        let settings = Motion.carry
        let length = CGFloat(settings.grabberLength)
        let thickness = CGFloat(settings.grabberThickness)
        let reach = CGFloat(settings.grabberReach)
        let edgeLine = CGFloat(settings.grabberInset) + thickness / 2
        let facesLeading = isVertical && center.x > carryLayer.width / 2
        let barShare: CGFloat = min(1, max(0, 1 - carry.morph * 2))
        let facesUp = !isVertical && center.y > carryLayer.height / 2
        let crossOffset = isVertical ? (facesLeading ? edgeLine - reach : reach - edgeLine) : 0
        let endOffset = isVertical ? 0 : (facesUp ? edgeLine - reach : reach - edgeLine)
        return Capsule()
            .fill(Palette.borderHover)
            .frame(width: isVertical ? thickness : length, height: isVertical ? length : thickness)
            .opacity(barShare)
            .frame(width: isVertical ? reach * 2 : length + reach * 2, height: isVertical ? length + reach * 2 : reach * 2)
            .contentShape(Rectangle())
            .offset(x: crossOffset, y: endOffset)
            .opacity(navigationMotion.areElementsShown ? 1 : 0)
            .animation(Motion.powerTwoOut(Motion.navigationElementMilliseconds), value: navigationMotion.areElementsShown)
            .gesture(carryGesture(center: center, waitsForTravel: false))
            .allowsHitTesting(carry.morph < 0.5 && navigationMotion.areElementsShown)
            .accessibilityLabel("Move the nav")
    }

    private func bubbleFace(center: CGPoint) -> some View {
        let shown = shownSize(carry.morph)
        let isReachable = carry.morph >= 0.5 || carry.isActive
        let faceShare: CGFloat = min(1, max(0, carry.morph * 2 - 1))
        let faceScale: CGFloat = 0.6 + 0.4 * min(1, max(0, carry.morph))
        return Capsule()
            .fill(Palette.borderHover)
            .frame(width: CGFloat(Motion.carry.grabberLength), height: CGFloat(Motion.carry.grabberThickness))
            .opacity(faceShare)
            .scaleEffect(faceScale)
            .frame(width: shown.width, height: shown.height)
            .contentShape(Capsule())
            .gesture(carryGesture(center: center, waitsForTravel: carry.state == .parked))
            .allowsHitTesting(isReachable)
            .accessibilityLabel("Expand the nav")
            .accessibilityAction { carry.expand() }
    }

    private func carryGesture(center: CGPoint, waitsForTravel: Bool) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(NavMetrics.layerSpace))
            .updating($isCarryGestureActive) { _, isActive, _ in isActive = true }
            .onChanged { value in
                if carry.state != .carried {
                    let travel = hypot(value.translation.width, value.translation.height)
                    guard !waitsForTravel || travel >= CGFloat(Motion.carry.tapSlop), sizingDrag == nil, toolReordering == nil, !isEdgeHidden, navigationMotion.isPresent else { return }
                    let current = carry.isStageCleared ? (carry.center ?? center) : center
                    swallowUntil = .distantFuture
                    edgeOffset = 0
                    Haptics.hold()
                    carry.grab(finger: value.startLocation, center: current)
                }
                carry.drag(finger: value.location)
            }
            .onEnded { _ in
                if carry.state == .carried {
                    carry.release()
                    swallowUntil = Date().addingTimeInterval(0.6)
                } else if waitsForTravel, carry.state == .parked {
                    carry.expand()
                }
            }
    }
}
