import SwiftUI

struct AsciiBackground: View {
    let color: Color
    let isMoving: Bool

    @Environment(\.accessibilityReduceMotion) private var reducesMotion

    private static let tokens = Tokens.shared.background
    private static let angle = Angle.degrees(tokens.angleDegrees)

    private static let art: String = {
        guard let url = Bundle.main.url(forResource: "background", withExtension: "txt"), let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text.trimmingCharacters(in: .newlines)
    }()

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: !isMoving || reducesMotion)) { timeline in
            Canvas { context, size in
                draw(in: context, size: size, seconds: timeline.date.timeIntervalSinceReferenceDate)
            }
        }
        .opacity(Self.tokens.opacity)
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    private func draw(in context: GraphicsContext, size: CGSize, seconds: TimeInterval) {
        guard !Self.art.isEmpty else { return }
        var context = context
        let text = context.resolve(Text(Self.art).font(Typography.mono(CGFloat(Self.tokens.fontSize))).foregroundColor(color))
        let measured = text.measure(in: CGSize(width: CGFloat.infinity, height: CGFloat.infinity))
        let gap = CGFloat(Self.tokens.gap)
        let tile = CGSize(width: max(1, measured.width + gap), height: max(1, measured.height + gap))
        let travel = seconds * Self.tokens.speed
        let shiftAlong = CGFloat((travel * cos(Self.angle.radians)).truncatingRemainder(dividingBy: Double(tile.width)))
        let shiftAcross = CGFloat((-travel * sin(Self.angle.radians)).truncatingRemainder(dividingBy: Double(tile.height)))
        let reach = hypot(size.width, size.height) / 2 + max(tile.width, tile.height)
        context.translateBy(x: size.width / 2, y: size.height / 2)
        context.rotate(by: Self.angle)
        let columns = Int((reach / tile.width).rounded(.up))
        let rows = Int((reach / tile.height).rounded(.up))
        for row in -rows...rows {
            for column in -columns...columns {
                let origin = CGPoint(x: CGFloat(column) * tile.width + shiftAlong, y: CGFloat(row) * tile.height + shiftAcross)
                context.draw(text, at: origin, anchor: .center)
            }
        }
    }
}
