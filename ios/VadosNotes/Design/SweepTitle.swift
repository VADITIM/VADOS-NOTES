import SwiftUI

struct SweepTitle: View {
    let text: String
    var size: CGFloat = 34
    var color: Color = Palette.accent
    var isSweeping = true

    @State private var barScale: CGFloat = 0
    @State private var barAnchor: UnitPoint = .leading
    @State private var isTextShown = false

    var body: some View {
        Text(text.uppercased())
            .font(Typography.heading(size))
            .foregroundColor(Palette.textBright)
            .lineLimit(1)
            .opacity(isTextShown || !isSweeping ? 1 : 0)
            .overlay(
                Rectangle()
                    .fill(color)
                    .scaleEffect(x: barScale, y: 1, anchor: barAnchor)
            )
            .task(id: text) {
                guard isSweeping else { return }
                await sweep()
            }
    }

    @MainActor
    private func sweep() async {
        isTextShown = false
        barAnchor = .leading
        barScale = 0
        withAnimation(Motion.powerThreeInOut(Motion.sweepGrowMilliseconds)) {
            barScale = 1
        }
        try? await Task.sleep(nanoseconds: UInt64(Motion.sweepGrowMilliseconds) * 1_000_000)
        guard !Task.isCancelled else { return }
        isTextShown = true
        barAnchor = .trailing
        withAnimation(Motion.powerThreeInOut(Motion.sweepRetractMilliseconds)) {
            barScale = 0
        }
    }
}

struct LabelReveal: ViewModifier {
    let isShown: Bool
    var delay = 0
    var color: Color = Palette.accent

    @State private var barScale: CGFloat = 0
    @State private var barAnchor: UnitPoint = .leading
    @State private var isTextShown = false
    @State private var step = 0

    func body(content: Content) -> some View {
        content
            .opacity(isTextShown ? 1 : 0)
            .overlay(
                Rectangle()
                    .fill(color)
                    .scaleEffect(x: barScale, y: 1, anchor: barAnchor)
                    .allowsHitTesting(false)
            )
            .onAppear {
                if isShown {
                    play(shown: true)
                }
            }
            .onChange(of: isShown) { _, shown in
                play(shown: shown)
            }
    }

    private func play(shown: Bool) {
        step += 1
        let current = step
        guard shown || isTextShown || barScale > 0 else { return }
        let grow = shown ? Motion.sweepGrowMilliseconds : Motion.navigationLeaveElementMilliseconds
        let retract = shown ? Motion.sweepRetractMilliseconds : Motion.navigationLeaveElementMilliseconds
        DispatchQueue.main.asyncAfter(deadline: .now() + Motion.seconds(shown ? delay : 0)) {
            guard current == step else { return }
            barAnchor = .leading
            withAnimation(Motion.powerThreeInOut(grow)) {
                barScale = 1
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Motion.seconds(grow)) {
                guard current == step else { return }
                isTextShown = shown
                barAnchor = .trailing
                withAnimation(Motion.powerThreeInOut(retract)) {
                    barScale = 0
                }
            }
        }
    }
}

extension View {
    func labelReveal(_ isShown: Bool, delay: Int = 0) -> some View {
        modifier(LabelReveal(isShown: isShown, delay: delay))
    }
}
