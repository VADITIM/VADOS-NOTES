import SwiftUI

enum Glyph {
    case pen
    case pencil
    case marker
    case eraser
    case text
    case undo
    case redo
    case back
    case plus
    case more
    case sync
    case check

    func path(in rect: CGRect) -> Path {
        let unit = min(rect.width, rect.height) / 24
        let origin = CGPoint(x: rect.midX - 12 * unit, y: rect.midY - 12 * unit)
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: origin.x + x * unit, y: origin.y + y * unit)
        }
        var path = Path()
        func polyline(_ coordinates: [(CGFloat, CGFloat)], isClosed: Bool = false) {
            guard let first = coordinates.first else { return }
            path.move(to: point(first.0, first.1))
            for coordinate in coordinates.dropFirst() {
                path.addLine(to: point(coordinate.0, coordinate.1))
            }
            if isClosed {
                path.closeSubpath()
            }
        }
        switch self {
        case .pen:
            polyline([(4, 20), (6, 14), (16, 4), (20, 8), (10, 18)], isClosed: true)
            polyline([(14, 6), (18, 10)])
            polyline([(4, 20), (7.5, 16.5)])
        case .pencil:
            polyline([(4, 20), (6, 14), (16, 4), (20, 8), (10, 18)], isClosed: true)
            polyline([(6, 14), (10, 18)])
            polyline([(13.5, 6.5), (17.5, 10.5)])
        case .marker:
            polyline([(6, 18), (6, 14), (15, 5), (19, 9), (10, 18)], isClosed: true)
            polyline([(4, 21), (11, 21)])
        case .eraser:
            polyline([(3, 15), (12, 6), (20, 14), (13, 21), (9, 21)], isClosed: true)
            polyline([(7.5, 10.5), (15.5, 18.5)])
            polyline([(13, 21), (21, 21)])
        case .text:
            polyline([(6, 6), (18, 6)])
            polyline([(12, 6), (12, 19)])
            polyline([(9, 19), (15, 19)])
        case .undo:
            polyline([(9, 5), (4, 10), (9, 15)])
            path.move(to: point(4, 10))
            path.addCurve(to: point(14, 19), control1: point(17, 10), control2: point(21, 14))
        case .redo:
            polyline([(15, 5), (20, 10), (15, 15)])
            path.move(to: point(20, 10))
            path.addCurve(to: point(10, 19), control1: point(7, 10), control2: point(3, 14))
        case .back:
            polyline([(15, 5), (8, 12), (15, 19)])
        case .plus:
            polyline([(12, 5), (12, 19)])
            polyline([(5, 12), (19, 12)])
        case .more:
            for x in [6.0, 12.0, 18.0] {
                path.addEllipse(in: CGRect(x: origin.x + (CGFloat(x) - 1.3) * unit, y: origin.y + 10.7 * unit, width: 2.6 * unit, height: 2.6 * unit))
            }
        case .sync:
            path.move(to: point(19, 9))
            path.addCurve(to: point(5, 10), control1: point(17, 4), control2: point(8, 3))
            polyline([(19, 4), (19, 9), (14, 9)])
            path.move(to: point(5, 15))
            path.addCurve(to: point(19, 14), control1: point(7, 20), control2: point(16, 21))
            polyline([(5, 20), (5, 15), (10, 15)])
        case .check:
            polyline([(5, 12.5), (10, 17.5), (19.5, 7)])
        }
        return path
    }
}

struct GlyphView: View {
    let glyph: Glyph
    var color: Color = Palette.textBright
    var size: CGFloat = 22

    var body: some View {
        GlyphShape(glyph: glyph)
            .stroke(color, style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
    }
}

struct GlyphShape: Shape {
    let glyph: Glyph

    func path(in rect: CGRect) -> Path {
        glyph.path(in: rect)
    }
}
