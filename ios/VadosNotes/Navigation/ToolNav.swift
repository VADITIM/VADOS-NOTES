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

enum NavMetrics {
    static let edgeMargin: CGFloat = 16
    static let bottomGap: CGFloat = 24
    static let carryDiameter: CGFloat = 58
    static let besideGap: CGFloat = 10
    static let layerSpace = "navLayer"
}

enum NavSide {
    case up
    case down
    case left
    case right
}

struct ToolNav<SubNav: View, PanelContent: View>: View {
    let face: String
    let groups: [[NavItem]]
    let selectedId: String?
    let subNavKey: String?
    let panelKey: String?
    let onCarry: () -> Void
    @ViewBuilder var subNav: (NavOrientation) -> SubNav
    @ViewBuilder var panel: () -> PanelContent

    @Namespace private var washSpace
    @State private var orientation: NavOrientation = .horizontal
    @State private var placement: NavPlacement?
    @State private var navSize: CGSize = .zero
    @State private var subNavSize: CGSize = .zero
    @State private var panelSize: CGSize = .zero
    @State private var carryPoint: CGPoint?
    @State private var swallowUntil = Date.distantPast


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

    private var entries: [Entry] {
        var entries: [Entry] = []
        for (index, group) in groups.enumerated() where !group.isEmpty {
            if !entries.isEmpty {
                entries.append(.separator("separator-\(face)-\(index)"))
            }
            entries.append(contentsOf: group.map(Entry.item))
        }
        return entries
    }

    var body: some View {
        GeometryReader { proxy in
            let layer = proxy.size
            let center = navCenter(in: layer)
            let side = outwardSide(center: center, layer: layer)
            let subNavCenter = beside(CGRect(x: center.x - navSize.width / 2, y: center.y - navSize.height / 2, width: navSize.width, height: navSize.height), size: subNavSize, side: side, layer: layer)
            let subNavRect = CGRect(x: subNavCenter.x - subNavSize.width / 2, y: subNavCenter.y - subNavSize.height / 2, width: subNavSize.width, height: subNavSize.height)
            ZStack(alignment: .topLeading) {
                if let subNavKey, carryPoint == nil {
                    subNavBody
                        .id(subNavKey)
                        .position(subNavCenter)
                        .transition(.scale(scale: 0.6, anchor: anchor(for: side)).combined(with: .opacity).animation(Motion.backOut(Motion.stateMilliseconds)))
                    if let panelKey {
                        panel()
                            .fixedSize()
                            .background(GeometryReader { panelProxy in Color.clear.preference(key: PanelSizeKey.self, value: panelProxy.size) })
                            .id(panelKey)
                            .position(beside(subNavRect, size: panelSize, side: side, layer: layer))
                            .transition(.scale(scale: 0.8, anchor: anchor(for: side)).combined(with: .opacity).animation(Motion.backOut(Motion.overlayEnterMilliseconds)))
                    }
                }
                navBody
                    .position(center)
                    .simultaneousGesture(carryGesture(layer: layer, center: center))
            }
            .coordinateSpace(name: NavMetrics.layerSpace)
            .onPreferenceChange(NavSizeKey.self) { navSize = $0 }
            .onPreferenceChange(SubNavSizeKey.self) { subNavSize = $0 }
            .onPreferenceChange(PanelSizeKey.self) { panelSize = $0 }
        }
        .onAppear {
            placement = Preferences.shared.navPlacement
            orientation = placement?.orientation == NavOrientation.vertical.rawValue ? .vertical : .horizontal
        }
    }

    @ViewBuilder
    private var navBody: some View {
        Group {
            if carryPoint != nil {
                GlyphView(name: "move", color: Palette.accent)
                    .frame(width: NavMetrics.carryDiameter, height: NavMetrics.carryDiameter)
                    .background(Circle().fill(Palette.panelSolid))
                    .overlay(Circle().stroke(Palette.accent, lineWidth: 1))
                    .transition(.scale.combined(with: .opacity))
            } else {
                stack
                    .padding(5)
                    .background(Capsule().fill(Palette.panelSolid))
                    .overlay(Capsule().stroke(Palette.border, lineWidth: 1))
                    .fixedSize()
                    .background(GeometryReader { navProxy in Color.clear.preference(key: NavSizeKey.self, value: navProxy.size) })
            }
        }
        .shadow(color: .black.opacity(0.45), radius: 16, y: 12)
        .animation(Motion.powerThreeInOut(Motion.stateMilliseconds * 2), value: face)
        .animation(Motion.powerThreeInOut(Motion.stateMilliseconds * 2), value: carryPoint == nil)
    }

    @ViewBuilder
    private var stack: some View {
        let layout = orientation == .horizontal ? AnyLayout(HStackLayout(spacing: 2)) : AnyLayout(VStackLayout(spacing: 2))
        layout {
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
        }
        .animation(Motion.powerTwoOut(Tokens.shared.motion.durations.navSlide), value: selectedId)
    }

    private func itemButton(_ item: NavItem) -> some View {
        let isSelected = item.id == selectedId
        let color = isSelected || item.isTinted ? item.tint : Palette.textBody
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
                        .font(Typography.monoBold(15))
                        .foregroundColor(color)
                } else {
                    GlyphView(name: item.glyph, color: color)
                        .scaleEffect(isSelected ? 1.06 : 1)
                }
                if let swatch = item.swatch {
                    Circle()
                        .fill(swatch)
                        .frame(width: 6, height: 6)
                        .overlay(Circle().stroke(Palette.borderControl, lineWidth: 1))
                        .offset(y: 16)
                }
            }
            .frame(width: orientation == .horizontal ? 56 : 48, height: orientation == .horizontal ? 48 : 52)
        }
        .disabled(!item.isEnabled)
        .opacity(item.isEnabled ? 1 : 0.38)
        .accessibilityLabel(item.label)
    }

    private var subNavBody: some View {
        let layout = orientation == .horizontal ? AnyLayout(HStackLayout(spacing: 2)) : AnyLayout(VStackLayout(spacing: 2))
        return layout {
            subNav(orientation)
        }
        .padding(5)
        .background(Capsule().fill(Palette.panelSolid))
        .overlay(Capsule().stroke(Palette.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 16, y: 12)
        .fixedSize()
        .background(GeometryReader { subProxy in Color.clear.preference(key: SubNavSizeKey.self, value: subProxy.size) })
    }

    private func clamped(_ point: CGPoint, size: CGSize, layer: CGSize) -> CGPoint {
        func clamp(_ value: CGFloat, _ half: CGFloat, _ total: CGFloat) -> CGFloat {
            total - NavMetrics.edgeMargin * 2 < half * 2 ? total / 2 : min(total - NavMetrics.edgeMargin - half, max(NavMetrics.edgeMargin + half, value))
        }
        return CGPoint(x: clamp(point.x, size.width / 2, layer.width), y: clamp(point.y, size.height / 2, layer.height))
    }

    private func navCenter(in layer: CGSize) -> CGPoint {
        if let carryPoint {
            return carryPoint
        }
        if let placement {
            return clamped(CGPoint(x: placement.x * layer.width, y: placement.y * layer.height), size: navSize, layer: layer)
        }
        return clamped(CGPoint(x: layer.width / 2, y: layer.height - NavMetrics.bottomGap - navSize.height / 2), size: navSize, layer: layer)
    }

    private func outwardSide(center: CGPoint, layer: CGSize) -> NavSide {
        if orientation == .vertical {
            return center.x > layer.width / 2 ? .left : .right
        }
        return center.y > layer.height / 2 ? .up : .down
    }

    private func anchor(for side: NavSide) -> UnitPoint {
        switch side {
        case .up: return .bottom
        case .down: return .top
        case .left: return .trailing
        case .right: return .leading
        }
    }

    private func beside(_ anchor: CGRect, size: CGSize, side: NavSide, layer: CGSize) -> CGPoint {
        let point: CGPoint
        switch side {
        case .up: point = CGPoint(x: anchor.midX, y: anchor.minY - NavMetrics.besideGap - size.height / 2)
        case .down: point = CGPoint(x: anchor.midX, y: anchor.maxY + NavMetrics.besideGap + size.height / 2)
        case .left: point = CGPoint(x: anchor.minX - NavMetrics.besideGap - size.width / 2, y: anchor.midY)
        case .right: point = CGPoint(x: anchor.maxX + NavMetrics.besideGap + size.width / 2, y: anchor.midY)
        }
        return clamped(point, size: size, layer: layer)
    }

    private func carryGesture(layer: CGSize, center: CGPoint) -> some Gesture {
        LongPressGesture(minimumDuration: Motion.seconds(Tokens.shared.motion.durations.navCarryHold), maximumDistance: 10)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(NavMetrics.layerSpace)))
            .onChanged { value in
                guard case .second(true, let drag) = value else { return }
                if carryPoint == nil {
                    swallowUntil = .distantFuture
                    Haptics.hold()
                    onCarry()
                }
                withAnimation(carryPoint == nil ? Motion.powerThreeInOut(Motion.stateMilliseconds * 2) : nil) {
                    carryPoint = drag?.location ?? center
                }
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

