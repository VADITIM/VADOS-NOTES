import SwiftUI

struct PressPop: ViewModifier {
    let isPressed: Bool

    func body(content: Content) -> some View {
        content
            .scaleEffect(isPressed ? CGFloat(Motion.scales.pressPop) : 1)
            .animation(
                isPressed ? Motion.powerTwoOut(Motion.pressMilliseconds) : Motion.backOut(Motion.releaseMilliseconds),
                value: isPressed
            )
    }
}

struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(PressPop(isPressed: configuration.isPressed))
            .onChange(of: configuration.isPressed) { _, isPressed in
                if isPressed {
                    Haptics.tick()
                }
            }
    }
}

struct HoldableButton<Label: View>: View {
    let action: () -> Void
    var onHold: ((CGRect) -> Void)?
    var onTapAt: ((CGRect) -> Void)?
    @ViewBuilder var label: () -> Label

    private static var tapConsumptionWindowSeconds: Double { 0.8 }

    @State private var frame: CGRect = .zero
    @State private var isHoldConsumingTap = false

    var body: some View {
        Button {
            if isHoldConsumingTap {
                isHoldConsumingTap = false
                return
            }
            if let onTapAt {
                onTapAt(frame)
            } else {
                action()
            }
        } label: {
            label()
                .contentShape(Rectangle())
                .background(
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear { frame = proxy.frame(in: .global) }
                            .onChange(of: proxy.frame(in: .global)) { _, newFrame in frame = newFrame }
                    }
                )
        }
        .buttonStyle(PressableStyle())
        .simultaneousGesture(
            LongPressGesture(minimumDuration: Motion.seconds(Motion.menuHoldMilliseconds))
                .onEnded { _ in
                    guard let onHold else { return }
                    isHoldConsumingTap = true
                    Haptics.hold()
                    onHold(frame)
                    DispatchQueue.main.asyncAfter(deadline: .now() + Self.tapConsumptionWindowSeconds) {
                        isHoldConsumingTap = false
                    }
                },
            including: onHold == nil ? .subviews : .all
        )
    }
}
