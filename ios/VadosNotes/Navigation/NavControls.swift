import SwiftUI

struct NavSeparator: View {
    let orientation: NavOrientation

    var body: some View {
        Rectangle()
            .fill(Palette.borderStrong)
            .frame(width: orientation == .horizontal ? 1 : 24, height: orientation == .horizontal ? 24 : 1)
            .padding(orientation == .horizontal ? .horizontal : .vertical, 4)
    }
}

struct SizeSlider: View {
    let orientation: NavOrientation
    let share: Double
    let previewDiameter: CGFloat
    let previewColor: Color
    let onChange: (Double) -> Void

    private static let length: CGFloat = 148
    private static let knob: CGFloat = 26
    @State private var dragStart: Double?
    @State private var isHeld = false

    private var isVertical: Bool { orientation == .vertical }

    var body: some View {
        let travel = Self.length - Self.knob
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
        .frame(width: isVertical ? 48 : Self.length, height: isVertical ? Self.length : 48)
        .padding(isVertical ? .vertical : .horizontal, 8)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if dragStart == nil {
                        dragStart = share
                        isHeld = true
                    }
                    let delta = isVertical ? -value.translation.height : value.translation.width
                    onChange(min(1, max(0, (dragStart ?? share) + Double(delta / travel))))
                }
                .onEnded { _ in
                    dragStart = nil
                    isHeld = false
                }
        )
        .animation(Motion.backOut(Motion.stateMilliseconds), value: isHeld)
    }
}

struct SwatchButton: View {
    let color: Color
    var diameter: CGFloat = 26
    var isSelected = false
    var isSizePreset = false
    let orientation: NavOrientation
    let onSelect: () -> Void
    var onRemove: (() -> Void)?

    @State private var isArmed = false

    var body: some View {
        ZStack {
            if isSizePreset {
                Circle()
                    .stroke(isArmed ? Palette.destructive : (isSelected ? Palette.textBright : .clear), lineWidth: 2)
                    .frame(width: 32, height: 32)
                    .scaleEffect(isSelected || isArmed ? 1 : 0.7)
                Circle()
                    .fill(color)
                    .frame(width: diameter, height: diameter)
            } else {
                Circle()
                    .fill(color)
                    .frame(width: 26, height: 26)
                    .overlay(Circle().stroke(Color.white.opacity(0.14), lineWidth: 1))
                    .padding(isSelected || isArmed ? 3 : 0)
                    .overlay(Circle().stroke(isArmed ? Palette.destructive : (isSelected ? Palette.textBright : .clear), lineWidth: 2))
                    .scaleEffect(isSelected || isArmed ? 0.82 : 1)
            }
            if isArmed {
                GlyphView(name: "close", color: Palette.destructive, size: 14)
                    .background(Circle().fill(Palette.panelSolid))
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(width: orientation == .horizontal ? 40 : 48, height: orientation == .horizontal ? 48 : 40)
        .contentShape(Rectangle())
        .onTapGesture {
            if isArmed {
                isArmed = false
                onRemove?()
            } else {
                onSelect()
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
        .animation(Motion.backOut(Motion.stateMilliseconds), value: isSelected)
        .animation(Motion.backOut(Motion.stateMilliseconds), value: isArmed)
    }
}

struct NavIconButton: View {
    let glyph: String
    var tint: Color = Palette.textBody
    var isSelected = false
    var isEnabled = true
    let orientation: NavOrientation
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            GlyphView(name: glyph, color: isSelected ? tint : Palette.textBody)
                .scaleEffect(isSelected ? 1.06 : 1)
                .frame(width: orientation == .horizontal ? 56 : 48, height: orientation == .horizontal ? 48 : 52)
                .background(Capsule().fill(Palette.pressedWash).opacity(isSelected ? 1 : 0))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.38)
    }
}

struct CaptionButton: View {
    let caption: String
    var isSelected = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(caption)
                .font(Typography.monoBold(15))
                .foregroundColor(isSelected ? Palette.textBright : Palette.textBody)
                .frame(width: 48, height: 48)
                .overlay(Circle().stroke(isSelected ? Palette.textBright : .clear, lineWidth: 2).frame(width: 38, height: 38).scaleEffect(isSelected ? 1 : 0.7))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .animation(Motion.backOut(Motion.stateMilliseconds), value: isSelected)
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
                .frame(width: 26, height: 26)
                .padding(isOpen ? 3 : 0)
                .overlay(Circle().stroke(isOpen ? Palette.accent : .clear, lineWidth: 2))
                .scaleEffect(isOpen ? 0.82 : 1)
                .frame(width: orientation == .horizontal ? 40 : 48, height: orientation == .horizontal ? 48 : 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .animation(Motion.backOut(Motion.stateMilliseconds), value: isOpen)
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
    let onChange: (String) -> Void

    @State private var hsv = HSV(hue: 0, saturation: 0, value: 1)
    @State private var hexText = ""
    @State private var isDragging = false
    @FocusState private var isHexFocused: Bool

    private static let wheelSize: CGFloat = 184

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MicroLabel(text: "Colour")
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
                    .onChanged { value in
                        isDragging = true
                        let x = value.location.x - Self.wheelSize / 2
                        let y = value.location.y - Self.wheelSize / 2
                        hsv.hue = (atan2(Double(y), Double(x)) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
                        hsv.saturation = min(1, Double(hypot(x, y) / (Self.wheelSize / 2)))
                        if hsv.value < 0.05 {
                            hsv.value = 1
                        }
                        emit()
                    }
                    .onEnded { _ in isDragging = false }
            )
            SizeSlider(orientation: .horizontal, share: hsv.value, previewDiameter: 0, previewColor: .clear) { share in
                hsv.value = share
                emit()
            }
            .frame(width: Self.wheelSize)
            .padding(.horizontal, -8)
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

    private func emit() {
        let hex = hsv.hex
        if !isHexFocused {
            hexText = hex
        }
        onChange(hex)
    }
}
