import SwiftUI

struct SweepTitle: View {
    let text: String
    var size: CGFloat = 34
    var color: Color = Palette.accent

    @State private var barScale: CGFloat = 0
    @State private var barAnchor: UnitPoint = .leading
    @State private var isTextShown = false

    var body: some View {
        Text(text.uppercased())
            .font(Typography.heading(size))
            .foregroundColor(Palette.textBright)
            .lineLimit(1)
            .opacity(isTextShown ? 1 : 0)
            .overlay(
                Rectangle()
                    .fill(color)
                    .scaleEffect(x: barScale, y: 1, anchor: barAnchor)
            )
            .task(id: text) {
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
