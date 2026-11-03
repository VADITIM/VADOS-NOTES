import SwiftUI
import UIKit

private struct NavigationTapsResumeKey: EnvironmentKey {
    static let defaultValue = Date.distantPast
}

struct PresetLiftCallbacks {
    var pressed: (Bool) -> Void = { _ in }
    var lifted: (Bool) -> Void = { _ in }
}

private struct PresetLiftCallbacksKey: EnvironmentKey {
    static let defaultValue = PresetLiftCallbacks()
}

extension EnvironmentValues {
    var navigationTapsResumeAt: Date {
        get { self[NavigationTapsResumeKey.self] }
        set { self[NavigationTapsResumeKey.self] = newValue }
    }

    var presetLiftCallbacks: PresetLiftCallbacks {
        get { self[PresetLiftCallbacksKey.self] }
        set { self[PresetLiftCallbacksKey.self] = newValue }
    }
}

struct PresetLiftState {
    var isLifted = false
    var isMoving = false
}

struct PresetStrip<Item: Hashable, Content: View>: View {
    let items: [Item]
    let orientation: NavOrientation
    var isKeyedByPosition = false
    let onReorder: ([Item]) -> Void
    @ViewBuilder let content: (Item, PresetLiftState) -> Content

    private struct Lift {
        let index: Int
        var order: [Int]
        let anchor: CGFloat
        var drag: CGFloat
    }

    @Environment(\.presetLiftCallbacks) private var callbacks
    @State private var lift: Lift?
    @State private var settling: (index: Int, offset: CGFloat)?
    @GestureState private var isPressing = false

    private static var space: String { "preset-strip" }

    private var pitch: CGFloat { SwatchButton.pitch }

    var body: some View {
        let layout = orientation == .horizontal ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
        layout {
            if isKeyedByPosition {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    cell(index, item)
                }
            } else {
                ForEach(Array(items.enumerated()), id: \.element) { index, item in
                    cell(index, item)
                }
            }
        }
        .coordinateSpace(name: Self.space)
        .onChange(of: isPressing) { _, pressing in
            callbacks.pressed(pressing)
            if !pressing {
                finish()
            }
        }
    }

    private func cell(_ index: Int, _ item: Item) -> some View {
        let isLifted = lift?.index == index
        let state = PresetLiftState(isLifted: isLifted, isMoving: isLifted && abs(lift?.drag ?? 0) > pitch / 4)
        let offset = offset(index)
        return content(item, state)
            .scaleEffect(isLifted ? CGFloat(Motion.scales.held) : 1)
            .offset(x: orientation == .horizontal ? offset : 0, y: orientation == .vertical ? offset : 0)
            .zIndex(isLifted || settling?.index == index ? 1 : 0)
            .animation(isLifted ? nil : Motion.placement, value: offset)
            .animation(Motion.backOut(Motion.stateMilliseconds), value: isLifted)
            .simultaneousGesture(liftGesture(index))
    }

    private func offset(_ index: Int) -> CGFloat {
        if let settling, settling.index == index {
            return settling.offset
        }
        guard let lift else { return 0 }
        if lift.index == index {
            return lift.drag
        }
        let position = lift.order.firstIndex(of: index) ?? index
        return CGFloat(position - index) * pitch
    }

    private func axisValue(_ point: CGPoint) -> CGFloat {
        orientation == .horizontal ? point.x : point.y
    }

    private func liftGesture(_ index: Int) -> some Gesture {
        LongPressGesture(minimumDuration: Motion.seconds(Motion.menuHoldMilliseconds), maximumDistance: 10)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space)))
            .updating($isPressing) { _, pressing, _ in pressing = true }
            .onChanged { value in
                guard case .second(true, let drag) = value, let drag else { return }
                if lift == nil {
                    lift = Lift(index: index, order: Array(items.indices), anchor: axisValue(drag.location), drag: 0)
                    callbacks.lifted(true)
                }
                guard var current = lift else { return }
                current.drag = axisValue(drag.location) - current.anchor
                step(&current)
                lift = current
            }
            .onEnded { _ in finish() }
    }

    private func step(_ current: inout Lift) {
        while let position = current.order.firstIndex(of: current.index) {
            let relative = current.drag - CGFloat(position - current.index) * pitch
            if position < current.order.count - 1, relative > pitch / 2 {
                current.order.swapAt(position, position + 1)
                Haptics.segment()
            } else if position > 0, relative < -pitch / 2 {
                current.order.swapAt(position, position - 1)
                Haptics.segment()
            } else {
                break
            }
        }
    }

    private func finish() {
        guard let current = lift else { return }
        let target = current.order.firstIndex(of: current.index) ?? current.index
        let residual = current.drag - CGFloat(target - current.index) * pitch
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            lift = nil
            if target != current.index {
                onReorder(current.order.map { items[$0] })
            }
            settling = (target, residual)
        }
        callbacks.lifted(false)
        Haptics.landed()
        DispatchQueue.main.async {
            withAnimation(Motion.placement) {
                settling?.offset = 0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Motion.seconds(Motion.stateMilliseconds * 2)) {
                settling = nil
            }
        }
    }
}

struct NavSeparator: View {
    let orientation: NavOrientation

    static let extent: CGFloat = 1 + 8 * NavMetrics.scale

    var body: some View {
        Rectangle()
            .fill(Palette.borderStrong)
            .frame(width: orientation == .horizontal ? 1 : 24 * NavMetrics.scale, height: orientation == .horizontal ? 24 * NavMetrics.scale : 1)
            .padding(orientation == .horizontal ? .horizontal : .vertical, 4 * NavMetrics.scale)
    }
}

struct SizeSlider: View {
    let orientation: NavOrientation
    let share: Double
    let previewDiameter: CGFloat
    let previewColor: Color
    var length: CGFloat = 148 * NavMetrics.scale
    let onChange: (Double) -> Void

    private static let knob: CGFloat = 26 * NavMetrics.scale
    private static let thickness: CGFloat = 48 * NavMetrics.scale
    @State private var dragStart: Double?
    @GestureState private var isHeld = false

    private var isVertical: Bool { orientation == .vertical }

    var body: some View {
        let travel = length - Self.knob
        ZStack(alignment: isVertical ? .bottom : .leading) {
            Capsule()
                .fill(Palette.borderStrong)
                .frame(width: isVertical ? (isHeld ? 8 : 4) : travel, height: isVertical ? travel : (isHeld ? 8 : 4))
                .overlay(alignment: isVertical ? .bottom : .leading) {
                    Capsule()
                        .fill(Palette.accent)
                        .frame(width: isVertical ? nil : travel * share, height: isVertical ? travel * share : nil)
                }
                .padding(isVertical ? .vertical : .horizontal, Self.knob / 2)
            Circle()
                .fill(Palette.raised)
                .overlay(Circle().stroke(Palette.borderHover, lineWidth: 1))
                .overlay(Circle().fill(previewColor).frame(width: previewDiameter, height: previewDiameter))
                .frame(width: Self.knob, height: Self.knob)
                .scaleEffect(isHeld ? 1.15 : 1)
                .offset(x: isVertical ? 0 : travel * share, y: isVertical ? -travel * share : 0)
        }
        .frame(width: isVertical ? Self.thickness : length, height: isVertical ? length : Self.thickness)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .updating($isHeld) { _, isActive, _ in isActive = true }
                .onChanged { value in
                    if dragStart == nil {
                        dragStart = share
                    }
                    let delta = isVertical ? -value.translation.height : value.translation.width
                    onChange(min(1, max(0, (dragStart ?? share) + Double(delta / travel))))
                }
        )
        .animation(Motion.backOut(Motion.stateMilliseconds), value: isHeld)
        .onChange(of: isHeld) { _, held in
            if !held {
                dragStart = nil
            }
        }
    }
}

struct NavSizeSlider: View {
    let orientation: NavOrientation
    let share: Double
    let color: Color
    let previewDiameter: CGFloat
    let startThickness: CGFloat
    let endThickness: CGFloat
    let caption: String

    static let knob: CGFloat = 34

    private var isVertical: Bool { orientation == .vertical }

    var body: some View {
        GeometryReader { proxy in
            let length = isVertical ? proxy.size.height : proxy.size.width
            let travel = max(1, length - Self.knob)
            ZStack(alignment: isVertical ? .bottom : .leading) {
                ConeTrack(startThickness: startThickness, endThickness: endThickness, isVertical: isVertical)
                    .fill(Palette.borderStrong)
                    .overlay {
                        ConeTrack(startThickness: startThickness, endThickness: endThickness, isVertical: isVertical)
                            .fill(Palette.accent)
                            .mask(alignment: isVertical ? .bottom : .leading) {
                                Rectangle()
                                    .frame(width: isVertical ? nil : travel * share, height: isVertical ? travel * share : nil)
                            }
                    }
                    .frame(width: isVertical ? endThickness : travel, height: isVertical ? travel : endThickness)
                    .padding(isVertical ? .vertical : .horizontal, Self.knob / 2)
                Circle()
                    .fill(Palette.raised)
                    .overlay(Circle().stroke(Palette.accent, lineWidth: 1.5))
                    .overlay(Circle().fill(color).frame(width: previewDiameter, height: previewDiameter))
                    .frame(width: Self.knob, height: Self.knob)
                    .overlay(alignment: isVertical ? .leading : .top) {
                        Text(caption)
                            .font(Typography.mono(10))
                            .foregroundColor(Palette.textBright)
                            .fixedSize()
                            .offset(x: isVertical ? Self.knob + 6 : 0, y: isVertical ? 0 : -16)
                    }
                    .offset(x: isVertical ? 0 : travel * share, y: isVertical ? -travel * share : 0)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: isVertical ? .bottom : .leading)
        }
        .allowsHitTesting(false)
    }
}

struct ConeTrack: Shape {
    let startThickness: CGFloat
    let endThickness: CGFloat
    let isVertical: Bool

    func path(in rect: CGRect) -> Path {
        let length = isVertical ? rect.height : rect.width
        let middle = (isVertical ? rect.width : rect.height) / 2
        let startRadius = startThickness / 2
        let endRadius = endThickness / 2
        var path = Path()
        path.move(to: CGPoint(x: startRadius, y: middle - startRadius))
        path.addLine(to: CGPoint(x: length - endRadius, y: middle - endRadius))
        path.addArc(center: CGPoint(x: length - endRadius, y: middle), radius: endRadius, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
        path.addLine(to: CGPoint(x: startRadius, y: middle + startRadius))
        path.addArc(center: CGPoint(x: startRadius, y: middle), radius: startRadius, startAngle: .degrees(90), endAngle: .degrees(270), clockwise: false)
        path.closeSubpath()
        guard isVertical else { return path.offsetBy(dx: rect.minX, dy: rect.minY) }
        let standing = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: rect.minX, ty: rect.minY + rect.height)
        return path.applying(standing)
    }
}

struct SelectionRing: View {
    let id: String
    let space: Namespace.ID
    var color: Color = Palette.textBright
    var diameter: CGFloat = 34 * NavMetrics.scale

    var body: some View {
        Circle()
            .stroke(color, lineWidth: 2)
            .frame(width: diameter, height: diameter)
            .matchedGeometryEffect(id: id, in: space)
    }
}

struct SwatchButton: View {
    let color: Color
    var diameter: CGFloat = 26 * NavMetrics.scale
    var isSelected = false
    var isSizePreset = false
    var caption: String?
    let orientation: NavOrientation
    var ring: (id: String, space: Namespace.ID)?
    var isPanelAnchor = false
    let onSelect: () -> Void
    var onRemove: (() -> Void)?
    var isMoving = false

    static let pitch: CGFloat = 34 * NavMetrics.scale
    private static let swatchDiameter: CGFloat = 26 * NavMetrics.scale

    @State private var isArmed = false
    @Environment(\.navigationTapsResumeAt) private var tapsResumeAt

    var body: some View {
        VStack(spacing: 2 * NavMetrics.scale) {
            ZStack {
                if isSelected, let ring {
                    SelectionRing(id: ring.id, space: ring.space, diameter: (isSizePreset ? 30 : 32) * NavMetrics.scale)
                }
                if isArmed {
                    Circle()
                        .stroke(Palette.destructive, lineWidth: 2)
                        .frame(width: 32 * NavMetrics.scale, height: 32 * NavMetrics.scale)
                }
                if isSizePreset {
                    Circle()
                        .fill(color)
                        .frame(width: diameter, height: diameter)
                } else {
                    Circle()
                        .fill(color)
                        .frame(width: Self.swatchDiameter, height: Self.swatchDiameter)
                        .overlay(Circle().stroke(Color.white.opacity(0.14), lineWidth: 1))
                        .scaleEffect(isSelected || isArmed ? 0.82 : 1)
                }
                if isArmed {
                    GlyphView(name: "close", color: Palette.destructive, size: 14 * NavMetrics.scale)
                        .background(Circle().fill(Palette.panelSolid))
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(width: Self.pitch, height: Self.pitch)
            if let caption {
                Text(caption)
                    .font(Typography.mono(8 * NavMetrics.scale))
                    .foregroundColor(isSelected ? Palette.textBright : Palette.textMuted)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .frame(width: orientation == .horizontal ? Self.pitch : 48 * NavMetrics.scale)
        .contentShape(Rectangle())
        .onTapGesture {
            guard Date() >= tapsResumeAt else { return }
            if isArmed {
                isArmed = false
                onRemove?()
            } else {
                withAnimation(Motion.selection) {
                    onSelect()
                }
            }
        }
        .onLongPressGesture(minimumDuration: Motion.seconds(Motion.menuHoldMilliseconds)) {
            guard onRemove != nil else { return }
            Haptics.hold()
            isArmed = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
                isArmed = false
            }
        }
        .onChange(of: isMoving) { _, moving in
            if moving {
                isArmed = false
            }
        }
        .animation(Motion.selection, value: isSelected)
        .animation(Motion.backOut(Motion.stateMilliseconds), value: isArmed)
        .reportsPanelAnchor(isPanelAnchor)
        .revealedElement()
    }
}

struct NavIconButton: View {
    let glyph: String
    var tint: Color = Palette.textBody
    var isSelected = false
    var isEnabled = true
    let orientation: NavOrientation
    var ring: (id: String, space: Namespace.ID)?
    let action: () -> Void

    var body: some View {
        let size = NavMetrics.itemSize(orientation)
        Button {
            withAnimation(Motion.selection) {
                action()
            }
        } label: {
            ZStack {
                if isSelected {
                    if let ring {
                        Capsule()
                            .fill(Palette.pressedWash)
                            .matchedGeometryEffect(id: ring.id, in: ring.space)
                    } else {
                        Capsule()
                            .fill(Palette.pressedWash)
                    }
                }
                GlyphView(name: glyph, color: isSelected ? tint : Palette.textBody, size: NavMetrics.glyphSize)
                    .scaleEffect(isSelected ? 1.06 : 1)
            }
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.38)
        .revealedElement()
    }
}

struct GroupEndButton: View {
    let isCollapsed: Bool
    var isEnabled = true
    let orientation: NavOrientation
    let action: () -> Void

    @Environment(\.navigationTapsResumeAt) private var tapsResumeAt

    var body: some View {
        let size = NavMetrics.itemSize(orientation)
        Button {
            guard Date() >= tapsResumeAt else { return }
            withAnimation(Motion.selection) {
                action()
            }
        } label: {
            PlusArrowShape(progress: isCollapsed ? 1 : 0, isVertical: orientation == .vertical)
                .stroke(Palette.textBody, style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
                .frame(width: NavMetrics.glyphSize, height: NavMetrics.glyphSize)
                .frame(width: size.width, height: size.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.38)
        .animation(Motion.backOut(Motion.stateMilliseconds), value: isCollapsed)
        .accessibilityLabel(isCollapsed ? "Show all" : "Add")
        .revealedElement()
    }
}

struct PlusArrowShape: Shape {
    var progress: CGFloat
    let isVertical: Bool

    private static let plus: [(CGPoint, CGPoint)] = [(CGPoint(x: 12, y: 5), CGPoint(x: 12, y: 19)), (CGPoint(x: 5, y: 12), CGPoint(x: 19, y: 12))]
    private static let arrow: [(CGPoint, CGPoint)] = [(CGPoint(x: 9, y: 5), CGPoint(x: 16, y: 12)), (CGPoint(x: 9, y: 19), CGPoint(x: 16, y: 12))]

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        let transform = CGAffineTransform(translationX: rect.midX - 12 * scale, y: rect.midY - 12 * scale).scaledBy(x: scale, y: scale)
        func blended(_ start: CGPoint, _ end: CGPoint) -> CGPoint {
            let point = CGPoint(x: start.x + (end.x - start.x) * progress, y: start.y + (end.y - start.y) * progress)
            return isVertical ? CGPoint(x: point.y, y: point.x) : point
        }
        var path = Path()
        for (line, target) in zip(Self.plus, Self.arrow) {
            path.move(to: blended(line.0, target.0))
            path.addLine(to: blended(line.1, target.1))
        }
        return path.applying(transform)
    }
}

struct CaptionButton: View {
    let caption: String
    var isSelected = false
    var ring: (id: String, space: Namespace.ID)?
    let action: () -> Void

    var body: some View {
        Button {
            withAnimation(Motion.selection) {
                action()
            }
        } label: {
            ZStack {
                if isSelected, let ring {
                    SelectionRing(id: ring.id, space: ring.space, diameter: 38 * NavMetrics.scale)
                }
                Text(caption)
                    .font(Typography.monoBold(15 * NavMetrics.scale))
                    .foregroundColor(isSelected ? Palette.textBright : Palette.textBody)
            }
            .frame(width: 44 * NavMetrics.scale, height: 48 * NavMetrics.scale)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .revealedElement()
    }
}

struct WheelButton: View {
    let isOpen: Bool
    let orientation: NavOrientation
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(AngularGradient(colors: [Color(hex: "#FF2E2E"), Color(hex: "#FFDD1B"), Color(hex: "#5BFD5B"), Color(hex: "#2EE6FF"), Color(hex: "#4D8BFF"), Color(hex: "#FF2E88"), Color(hex: "#FF2E2E")], center: .center))
                .frame(width: 26 * NavMetrics.scale, height: 26 * NavMetrics.scale)
                .padding(isOpen ? 3 * NavMetrics.scale : 0)
                .overlay(Circle().stroke(isOpen ? Palette.accent : .clear, lineWidth: 2))
                .scaleEffect(isOpen ? 0.82 : 1)
                .frame(width: orientation == .horizontal ? 40 * NavMetrics.scale : 48 * NavMetrics.scale, height: orientation == .horizontal ? 48 * NavMetrics.scale : 40 * NavMetrics.scale)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .animation(Motion.backOut(Motion.stateMilliseconds), value: isOpen)
        .reportsPanelAnchor(isOpen)
        .revealedElement()
    }
}

struct PanelAnchorKey: PreferenceKey {
    static var defaultValue: CGRect?
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        value = nextValue() ?? value
    }
}

extension View {
    func reportsPanelAnchor(_ isAnchor: Bool) -> some View {
        background(GeometryReader { proxy in Color.clear.preference(key: PanelAnchorKey.self, value: isAnchor ? proxy.frame(in: .named(NavMetrics.layerSpace)) : nil) })
    }
}

enum ColorVariations {
    static let count = 3
    static let saturationStep = 0.22
    static let valueStep = 0.05
    static let neutralValueStep = 0.18
    static let neutralSaturation = 0.08
    static let saturationRange = 0.06...1.0
    static let valueRange = 0.06...1.0
    private static let stepOrder = [-1, 1, -2, 2, -3, 3, -4, 4]

    static func around(_ hex: String) -> [String] {
        let base = HSV(hex: hex)
        let isNeutral = base.saturation < neutralSaturation
        let steps = stepOrder.filter { step in
            isNeutral ? valueRange.contains(base.value + Double(step) * neutralValueStep) : saturationRange.contains(base.saturation + Double(step) * saturationStep)
        }
        let chosen = (Array(steps.prefix(count)) + [0]).sorted()
        return chosen.map { step in
            guard step != 0 else { return hex.uppercased() }
            var variation = base
            if isNeutral {
                variation.value = base.value + Double(step) * neutralValueStep
            } else {
                variation.saturation = base.saturation + Double(step) * saturationStep
                variation.value = min(valueRange.upperBound, max(valueRange.lowerBound, base.value + Double(step) * valueStep))
            }
            return variation.hex.uppercased()
        }
    }
}

struct VariationPanel: View {
    let colors: [String]
    let main: String
    let selected: String
    let orientation: NavOrientation
    let display: (String) -> Color
    let onPick: (String) -> Void

    @Namespace private var ringSpace

    private static let markLength: CGFloat = 12 * NavMetrics.scale
    private static let markThickness: CGFloat = 2
    private static let markGap: CGFloat = 1 * NavMetrics.scale

    var body: some View {
        let layout = orientation == .horizontal ? AnyLayout(HStackLayout(spacing: NavMetrics.spacing)) : AnyLayout(VStackLayout(spacing: NavMetrics.spacing))
        layout {
            ForEach(Array(colors.enumerated()), id: \.offset) { _, color in
                SwatchButton(color: display(color), isSelected: color == selected.uppercased(), orientation: orientation, ring: ("variation-ring", ringSpace), onSelect: { onPick(color) })
                    .overlay(alignment: orientation == .horizontal ? .bottom : .trailing) {
                        if color == main.uppercased() {
                            mainMark
                                .matchedGeometryEffect(id: "main-mark", in: ringSpace)
                        }
                    }
            }
        }
    }

    private var mainMark: some View {
        Capsule()
            .fill(Palette.textBright)
            .frame(width: orientation == .horizontal ? Self.markLength : Self.markThickness, height: orientation == .horizontal ? Self.markThickness : Self.markLength)
            .offset(x: orientation == .horizontal ? 0 : Self.markGap, y: orientation == .horizontal ? Self.markGap : 0)
            .revealedElement()
            .accessibilityLabel("Main colour")
    }
}

struct HSV: Equatable {
    var hue: Double
    var saturation: Double
    var value: Double

    init(hue: Double, saturation: Double, value: Double) {
        self.hue = hue
        self.saturation = saturation
        self.value = value
    }

    init(hex: String) {
        let components = HexColor.components(hex)
        let maximum = max(components.red, components.green, components.blue)
        let minimum = min(components.red, components.green, components.blue)
        let chroma = maximum - minimum
        var hue = 0.0
        if chroma > 0 {
            if maximum == components.red {
                hue = 60 * ((components.green - components.blue) / chroma).truncatingRemainder(dividingBy: 6)
            } else if maximum == components.green {
                hue = 60 * ((components.blue - components.red) / chroma + 2)
            } else {
                hue = 60 * ((components.red - components.green) / chroma + 4)
            }
        }
        self.init(hue: (hue + 360).truncatingRemainder(dividingBy: 360), saturation: maximum == 0 ? 0 : chroma / maximum, value: maximum)
    }

    var hex: String {
        let chroma = value * saturation
        let sector = (hue / 60).truncatingRemainder(dividingBy: 6)
        let second = chroma * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
        let base = value - chroma
        let rgb: (Double, Double, Double)
        switch sector {
        case ..<1: rgb = (chroma, second, 0)
        case ..<2: rgb = (second, chroma, 0)
        case ..<3: rgb = (0, chroma, second)
        case ..<4: rgb = (0, second, chroma)
        case ..<5: rgb = (second, 0, chroma)
        default: rgb = (chroma, 0, second)
        }
        return HexColor.hex(red: rgb.0 + base, green: rgb.1 + base, blue: rgb.2 + base)
    }
}

struct ColorPanel: View {
    let color: String
    var isPicking = false
    var onPick: (() -> Void)?
    let onChange: (String) -> Void

    @State private var hsv = HSV(hue: 0, saturation: 0, value: 1)
    @State private var hexText = ""
    @GestureState private var isDragging = false
    @FocusState private var isHexFocused: Bool

    private static let wheelSize: CGFloat = 184

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                MicroLabel(text: "Colour")
                Spacer()
                pickButton
            }
            ZStack {
                Circle()
                    .fill(AngularGradient(colors: stride(from: 0.0, through: 360, by: 30).map { Color(hex: HSV(hue: $0.truncatingRemainder(dividingBy: 360), saturation: 1, value: hsv.value).hex) }, center: .center))
                Circle()
                    .fill(RadialGradient(colors: [Color(hex: HSV(hue: 0, saturation: 0, value: hsv.value).hex), Color(hex: HSV(hue: 0, saturation: 0, value: hsv.value).hex).opacity(0)], center: .center, startRadius: 0, endRadius: Self.wheelSize / 2))
                Circle()
                    .fill(Color(hex: hsv.hex))
                    .frame(width: 18, height: 18)
                    .overlay(Circle().stroke(Color.white, lineWidth: 2))
                    .overlay(Circle().stroke(Color.black.opacity(0.6), lineWidth: 1).padding(-1.5))
                    .offset(x: cos(hsv.hue * .pi / 180) * hsv.saturation * Self.wheelSize / 2, y: sin(hsv.hue * .pi / 180) * hsv.saturation * Self.wheelSize / 2)
            }
            .frame(width: Self.wheelSize, height: Self.wheelSize)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($isDragging) { _, isActive, _ in isActive = true }
                    .onChanged { value in
                        let x = value.location.x - Self.wheelSize / 2
                        let y = value.location.y - Self.wheelSize / 2
                        hsv.hue = (atan2(Double(y), Double(x)) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
                        hsv.saturation = min(1, Double(hypot(x, y) / (Self.wheelSize / 2)))
                        if hsv.value < 0.05 {
                            hsv.value = 1
                        }
                        emit()
                    }
            )
            SizeSlider(orientation: .horizontal, share: hsv.value, previewDiameter: 0, previewColor: .clear, length: Self.wheelSize) { share in
                hsv.value = share
                emit()
            }
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(hex: hsv.hex))
                    .frame(width: 40, height: 40)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.14), lineWidth: 1))
                TextField("", text: $hexText)
                    .font(Typography.mono(14))
                    .foregroundColor(Palette.textPrimary)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .focused($isHexFocused)
                    .padding(.horizontal, 12)
                    .frame(height: 40)
                    .background(Squircle.slot.fill(Palette.sunkenDeep))
                    .overlay(Squircle.slot.stroke(Palette.borderControl, lineWidth: 1))
                    .onChange(of: hexText) { _, text in
                        var candidate = text.trimmingCharacters(in: .whitespaces).uppercased()
                        if !candidate.hasPrefix("#") {
                            candidate = "#" + candidate
                        }
                        guard isHexFocused, candidate.count == 7, UInt64(candidate.dropFirst(), radix: 16) != nil else { return }
                        hsv = HSV(hex: candidate)
                        onChange(candidate)
                    }
            }
        }
        .padding(16)
        .frame(width: 216)
        .background(Squircle.panel.fill(Palette.panelSolid))
        .overlay(Squircle.panel.stroke(Palette.border, lineWidth: 1))
        .onAppear {
            hsv = HSV(hex: color)
            hexText = color.uppercased()
        }
        .onChange(of: color) { _, next in
            guard !isDragging, !isHexFocused, next.uppercased() != hsv.hex else { return }
            hsv = HSV(hex: next)
            hexText = next.uppercased()
        }
    }

    private var pickButton: some View {
        Button {
            Haptics.tick()
            onPick?()
        } label: {
            HStack(spacing: 6) {
                GlyphView(name: "eyedropper", color: isPicking ? Palette.accent : Palette.textMuted, size: 16)
                ZStack {
                    Text(isPicking ? "PICKING" : "PICK")
                        .font(Typography.monoBold(10))
                        .tracking(1.5)
                        .foregroundColor(isPicking ? Palette.accent : Palette.textMuted)
                        .fixedSize()
                        .id(isPicking)
                        .transition(.pop)
                }
                .animation(Motion.powerThreeInOut(Motion.navigationSwitchMilliseconds * 2), value: isPicking)
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Squircle(radius: 9).fill(Palette.sunkenDeep))
            .contentShape(Squircle(radius: 9))
        }
        .buttonStyle(PressableStyle())
    }

    private func emit() {
        let hex = hsv.hex
        if !isHexFocused {
            hexText = hex
        }
        onChange(hex)
    }
}
