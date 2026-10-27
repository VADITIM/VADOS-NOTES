import SwiftUI

enum SVGPath {
    private static var cache: [String: Path] = [:]

    static func path(_ data: String) -> Path {
        if let cached = cache[data] {
            return cached
        }
        let parsed = parse(data)
        cache[data] = parsed
        return parsed
    }

    private static func tokens(_ data: String) -> [String] {
        var result: [String] = []
        var number = ""
        func flush() {
            if !number.isEmpty {
                result.append(number)
                number = ""
            }
        }
        for character in data {
            if character.isLetter && character != "e" {
                flush()
                result.append(String(character))
            } else if character == "-" && !number.isEmpty && number.last != "e" {
                flush()
                number = "-"
            } else if character == "." && number.contains(".") {
                flush()
                number = "."
            } else if character.isNumber || character == "." || character == "-" || character == "e" {
                number.append(character)
            } else {
                flush()
            }
        }
        flush()
        return result
    }

    private static func parse(_ data: String) -> Path {
        var path = Path()
        let items = tokens(data)
        var index = 0
        var command: Character = "M"
        var current = CGPoint.zero
        var start = CGPoint.zero
        func number() -> CGFloat {
            defer { index += 1 }
            return index < items.count ? CGFloat(Double(items[index]) ?? 0) : 0
        }
        func isNumberNext() -> Bool {
            index < items.count && !(items[index].first?.isLetter ?? false)
        }
        while index < items.count {
            if let first = items[index].first, first.isLetter {
                command = first
                index += 1
            }
            let isRelative = command.isLowercase
            let base = isRelative ? current : .zero
            switch command.uppercased().first ?? "M" {
            case "M":
                let point = CGPoint(x: base.x + number(), y: base.y + number())
                path.move(to: point)
                current = point
                start = point
                command = isRelative ? "l" : "L"
            case "L":
                let point = CGPoint(x: base.x + number(), y: base.y + number())
                path.addLine(to: point)
                current = point
            case "H":
                current = CGPoint(x: (isRelative ? current.x : 0) + number(), y: current.y)
                path.addLine(to: current)
            case "V":
                current = CGPoint(x: current.x, y: (isRelative ? current.y : 0) + number())
                path.addLine(to: current)
            case "C":
                let first = CGPoint(x: base.x + number(), y: base.y + number())
                let second = CGPoint(x: base.x + number(), y: base.y + number())
                let end = CGPoint(x: base.x + number(), y: base.y + number())
                path.addCurve(to: end, control1: first, control2: second)
                current = end
            case "Q":
                let control = CGPoint(x: base.x + number(), y: base.y + number())
                let end = CGPoint(x: base.x + number(), y: base.y + number())
                path.addQuadCurve(to: end, control: control)
                current = end
            case "A":
                let radiusX = abs(number())
                let radiusY = abs(number())
                let rotation = number()
                let isLarge = number() != 0
                let isSweep = number() != 0
                let end = CGPoint(x: base.x + number(), y: base.y + number())
                addArc(to: &path, from: current, to: end, radiusX: radiusX, radiusY: radiusY, rotation: rotation, isLarge: isLarge, isSweep: isSweep)
                current = end
            case "Z":
                path.closeSubpath()
                current = start
                if isNumberNext() {
                    command = "L"
                }
                continue
            default:
                index += 1
            }
        }
        return path
    }

    private static func addArc(to path: inout Path, from start: CGPoint, to end: CGPoint, radiusX: CGFloat, radiusY: CGFloat, rotation: CGFloat, isLarge: Bool, isSweep: Bool) {
        guard radiusX > 0, radiusY > 0, start != end else {
            path.addLine(to: end)
            return
        }
        let angle = rotation * .pi / 180
        let cosine = cos(angle)
        let sine = sin(angle)
        let halfX = (start.x - end.x) / 2
        let halfY = (start.y - end.y) / 2
        let primeX = cosine * halfX + sine * halfY
        let primeY = -sine * halfX + cosine * halfY
        var rx = radiusX
        var ry = radiusY
        let lambda = (primeX * primeX) / (rx * rx) + (primeY * primeY) / (ry * ry)
        if lambda > 1 {
            rx *= sqrt(lambda)
            ry *= sqrt(lambda)
        }
        let numerator = max(0, rx * rx * ry * ry - rx * rx * primeY * primeY - ry * ry * primeX * primeX)
        let denominator = rx * rx * primeY * primeY + ry * ry * primeX * primeX
        var factor = denominator == 0 ? 0 : sqrt(numerator / denominator)
        if isLarge == isSweep {
            factor = -factor
        }
        let centerPrimeX = factor * rx * primeY / ry
        let centerPrimeY = -factor * ry * primeX / rx
        let centerX = cosine * centerPrimeX - sine * centerPrimeY + (start.x + end.x) / 2
        let centerY = sine * centerPrimeX + cosine * centerPrimeY + (start.y + end.y) / 2
        func vectorAngle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let sign: CGFloat = ux * vy - uy * vx < 0 ? -1 : 1
            let dot = (ux * vx + uy * vy) / (sqrt(ux * ux + uy * uy) * sqrt(vx * vx + vy * vy))
            return sign * acos(min(1, max(-1, dot)))
        }
        let startAngle = vectorAngle(1, 0, (primeX - centerPrimeX) / rx, (primeY - centerPrimeY) / ry)
        var delta = vectorAngle((primeX - centerPrimeX) / rx, (primeY - centerPrimeY) / ry, (-primeX - centerPrimeX) / rx, (-primeY - centerPrimeY) / ry)
        if !isSweep && delta > 0 {
            delta -= 2 * .pi
        } else if isSweep && delta < 0 {
            delta += 2 * .pi
        }
        let segments = max(1, Int(ceil(abs(delta) / (.pi / 2))))
        let step = delta / CGFloat(segments)
        let handle = 4.0 / 3.0 * tan(step / 4)
        func pointOn(_ theta: CGFloat) -> CGPoint {
            CGPoint(x: centerX + rx * cos(theta) * cosine - ry * sin(theta) * sine, y: centerY + rx * cos(theta) * sine + ry * sin(theta) * cosine)
        }
        func derivative(_ theta: CGFloat) -> CGPoint {
            CGPoint(x: -rx * sin(theta) * cosine - ry * cos(theta) * sine, y: -rx * sin(theta) * sine + ry * cos(theta) * cosine)
        }
        for segment in 0..<segments {
            let first = startAngle + step * CGFloat(segment)
            let second = first + step
            let from = pointOn(first)
            let to = pointOn(second)
            let fromDerivative = derivative(first)
            let toDerivative = derivative(second)
            path.addCurve(
                to: to,
                control1: CGPoint(x: from.x + handle * fromDerivative.x, y: from.y + handle * fromDerivative.y),
                control2: CGPoint(x: to.x - handle * toDerivative.x, y: to.y - handle * toDerivative.y)
            )
        }
    }
}

struct GlyphShape: Shape {
    let name: String

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        let transform = CGAffineTransform(translationX: rect.midX - 12 * scale, y: rect.midY - 12 * scale).scaledBy(x: scale, y: scale)
        return SVGPath.path(Tokens.shared.glyphs[name] ?? "").applying(transform)
    }
}

struct GlyphView: View {
    let name: String
    var color: Color = Palette.textBright
    var size: CGFloat = 22

    var body: some View {
        GlyphShape(name: name)
            .stroke(color, style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
    }
}
