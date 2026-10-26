import SwiftUI

struct Squircle: Shape {
    var radius: CGFloat

    private static let exponent = 5.0
    private static let stepsPerCorner = 12
    private static let extentPerRadius: CGFloat = 1.8

    static let sheet = Squircle(radius: 30)
    static let panel = Squircle(radius: 22)
    static let tile = Squircle(radius: 18)
    static let slot = Squircle(radius: 14)

    func path(in rect: CGRect) -> Path {
        let extent = min(radius * Self.extentPerRadius, min(rect.width, rect.height) / 2)
        guard extent > 0 else { return Path(rect) }
        var path = Path()
        addCorner(&path, center: CGPoint(x: rect.minX + extent, y: rect.minY + extent), extent: extent, startAngle: .pi, isFirst: true)
        addCorner(&path, center: CGPoint(x: rect.maxX - extent, y: rect.minY + extent), extent: extent, startAngle: 1.5 * .pi, isFirst: false)
        addCorner(&path, center: CGPoint(x: rect.maxX - extent, y: rect.maxY - extent), extent: extent, startAngle: 0, isFirst: false)
        addCorner(&path, center: CGPoint(x: rect.minX + extent, y: rect.maxY - extent), extent: extent, startAngle: 0.5 * .pi, isFirst: false)
        path.closeSubpath()
        return path
    }

    private func addCorner(_ path: inout Path, center: CGPoint, extent: CGFloat, startAngle: Double, isFirst: Bool) {
        for step in 0...Self.stepsPerCorner {
            let angle = startAngle + (Double.pi / 2) * Double(step) / Double(Self.stepsPerCorner)
            let point = CGPoint(x: center.x + extent * superellipse(cos(angle)), y: center.y + extent * superellipse(sin(angle)))
            if isFirst && step == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
    }

    private func superellipse(_ value: Double) -> CGFloat {
        let magnitude = pow(abs(value), 2.0 / Self.exponent)
        return CGFloat(value < 0 ? -magnitude : magnitude)
    }
}

struct Panel<Content: View>: View {
    var shape: Squircle = .panel
    var fill: Color = Palette.panelSolid
    var border: Color = Palette.border
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .background(shape.fill(fill))
            .overlay(shape.stroke(border, lineWidth: 1))
    }
}
