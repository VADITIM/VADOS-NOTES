import Foundation

public enum ShapeOutline: String, Codable, Sendable {
    case polygon
    case curve
}

public struct ShapeGeometry: Codable, Equatable, Sendable {
    public var outline: ShapeOutline
    public var name: String
    public var anchors: [Point]
    public var handles: [Point]?
    public var radii: [Double]?

    public init(outline: ShapeOutline, name: String, anchors: [Point], handles: [Point]? = nil, radii: [Double]? = nil) {
        self.outline = outline
        self.name = name
        self.anchors = anchors
        self.handles = handles
        self.radii = radii
    }

    public static let curveSegments = 8
    public static let samplesPerCurveSegment = 16
    public static let samplesPerCorner = 8

    public static func polygon(_ name: String, _ anchors: [Point]) -> ShapeGeometry {
        ShapeGeometry(outline: .polygon, name: name, anchors: anchors.map(StrokeGeometry.rounded), radii: Array(repeating: 0, count: anchors.count))
    }

    public static func ellipse(_ name: String, center: Point, radiusX: Double, radiusY: Double) -> ShapeGeometry {
        let count = curveSegments
        let span = 2 * Double.pi / Double(count)
        let reach = 4.0 / 3.0 * tan(span / 4)
        var anchors: [Point] = []
        var handles: [Point] = []
        for index in 0..<count {
            let angle = Double(index) * span
            anchors.append(Point(x: center.x + radiusX * cos(angle), y: center.y + radiusY * sin(angle)))
        }
        for index in 0..<count {
            let angle = Double(index) * span
            let next = Double(index + 1) * span
            let start = anchors[index]
            let end = anchors[(index + 1) % count]
            handles.append(Point(x: start.x - radiusX * sin(angle) * reach, y: start.y + radiusY * cos(angle) * reach))
            handles.append(Point(x: end.x + radiusX * sin(next) * reach, y: end.y - radiusY * cos(next) * reach))
        }
        return ShapeGeometry(outline: .curve, name: name, anchors: anchors.map(StrokeGeometry.rounded), handles: handles.map(StrokeGeometry.rounded))
    }

    public var isValid: Bool {
        switch outline {
        case .polygon:
            return anchors.count >= 3 && (radii == nil || radii?.count == anchors.count)
        case .curve:
            return anchors.count >= 2 && handles?.count == anchors.count * 2
        }
    }

    public func outlinePoints() -> [Point] {
        guard isValid else { return anchors }
        var points: [Point] = []
        switch outline {
        case .curve:
            let handles = self.handles ?? []
            for index in anchors.indices {
                let start = anchors[index]
                let first = handles[index * 2]
                let second = handles[index * 2 + 1]
                let end = anchors[(index + 1) % anchors.count]
                for step in 0..<Self.samplesPerCurveSegment {
                    points.append(Self.cubic(start, first, second, end, Double(step) / Double(Self.samplesPerCurveSegment)))
                }
            }
        case .polygon:
            for index in anchors.indices {
                points.append(contentsOf: cornerPoints(index))
            }
        }
        if let first = points.first {
            points.append(first)
        }
        return Ink.cleaned(points)
    }

    private static func cubic(_ start: Point, _ first: Point, _ second: Point, _ end: Point, _ share: Double) -> Point {
        let rest = 1 - share
        let a = rest * rest * rest
        let b = 3 * rest * rest * share
        let c = 3 * rest * share * share
        let d = share * share * share
        return Point(x: a * start.x + b * first.x + c * second.x + d * end.x, y: a * start.y + b * first.y + c * second.y + d * end.y)
    }

    private struct Corner {
        let point: Point
        let towardPrevious: Point
        let towardNext: Point
        let previousLength: Double
        let nextLength: Double
        let halfAngle: Double

        var bisector: Point? {
            let x = towardPrevious.x + towardNext.x
            let y = towardPrevious.y + towardNext.y
            let length = (x * x + y * y).squareRoot()
            guard length > 1e-9 else { return nil }
            return Point(x: x / length, y: y / length)
        }
    }

    private func corner(_ index: Int) -> Corner? {
        guard outline == .polygon, anchors.count >= 3 else { return nil }
        let count = anchors.count
        let point = anchors[index]
        let previous = anchors[(index + count - 1) % count]
        let next = anchors[(index + 1) % count]
        let previousLength = StrokeGeometry.distance(point, previous)
        let nextLength = StrokeGeometry.distance(point, next)
        guard previousLength > 1e-9, nextLength > 1e-9 else { return nil }
        let towardPrevious = Point(x: (previous.x - point.x) / previousLength, y: (previous.y - point.y) / previousLength)
        let towardNext = Point(x: (next.x - point.x) / nextLength, y: (next.y - point.y) / nextLength)
        let cosine = max(-1, min(1, towardPrevious.x * towardNext.x + towardPrevious.y * towardNext.y))
        return Corner(point: point, towardPrevious: towardPrevious, towardNext: towardNext, previousLength: previousLength, nextLength: nextLength, halfAngle: acos(cosine) / 2)
    }

    public func maximumRadius(at index: Int) -> Double {
        guard let corner = corner(index), corner.halfAngle > 1e-6, corner.halfAngle < Double.pi / 2 - 1e-6 else { return 0 }
        return min(corner.previousLength, corner.nextLength) / 2 * tan(corner.halfAngle)
    }

    public func radius(at index: Int) -> Double {
        guard let radii, radii.indices.contains(index) else { return 0 }
        return max(0, min(radii[index], maximumRadius(at: index)))
    }

    private func cornerPoints(_ index: Int) -> [Point] {
        let radius = radius(at: index)
        guard radius > 0, let corner = corner(index), let bisector = corner.bisector else { return [anchors[index]] }
        let reach = radius / tan(corner.halfAngle)
        let start = Point(x: corner.point.x + corner.towardPrevious.x * reach, y: corner.point.y + corner.towardPrevious.y * reach)
        let end = Point(x: corner.point.x + corner.towardNext.x * reach, y: corner.point.y + corner.towardNext.y * reach)
        let centreDistance = radius / sin(corner.halfAngle)
        let centre = Point(x: corner.point.x + bisector.x * centreDistance, y: corner.point.y + bisector.y * centreDistance)
        let startAngle = atan2(start.y - centre.y, start.x - centre.x)
        var sweep = atan2(end.y - centre.y, end.x - centre.x) - startAngle
        while sweep > Double.pi {
            sweep -= 2 * Double.pi
        }
        while sweep < -Double.pi {
            sweep += 2 * Double.pi
        }
        return (0...Self.samplesPerCorner).map { step in
            let angle = startAngle + sweep * Double(step) / Double(Self.samplesPerCorner)
            return Point(x: centre.x + radius * cos(angle), y: centre.y + radius * sin(angle))
        }
    }

    public func radiusHandle(at index: Int, inset: Double) -> Point? {
        guard let corner = corner(index), let bisector = corner.bisector, corner.halfAngle > 1e-6 else { return nil }
        let distance = inset + radius(at: index) * (1 / sin(corner.halfAngle) - 1)
        return Point(x: corner.point.x + bisector.x * distance, y: corner.point.y + bisector.y * distance)
    }

    public func radius(at index: Int, forHandle point: Point, inset: Double) -> Double {
        guard let corner = corner(index), let bisector = corner.bisector, corner.halfAngle > 1e-6 else { return 0 }
        let along = (point.x - corner.point.x) * bisector.x + (point.y - corner.point.y) * bisector.y
        let growth = 1 / sin(corner.halfAngle) - 1
        guard growth > 1e-9 else { return 0 }
        return max(0, min(maximumRadius(at: index), (along - inset) / growth))
    }

    public func withRadius(_ radius: Double, at index: Int) -> ShapeGeometry {
        guard outline == .polygon, anchors.indices.contains(index) else { return self }
        var shape = self
        var radii = self.radii ?? Array(repeating: 0, count: anchors.count)
        radii[index] = (max(0, min(radius, maximumRadius(at: index))) * StrokeGeometry.pointPrecision).rounded() / StrokeGeometry.pointPrecision
        shape.radii = radii
        return shape
    }

    public func withAllRadii(_ radius: Double) -> ShapeGeometry {
        anchors.indices.reduce(self) { shape, index in shape.withRadius(radius, at: index) }
    }

    public func movingAnchor(_ index: Int, to point: Point) -> ShapeGeometry {
        guard anchors.indices.contains(index) else { return self }
        var shape = self
        let target = StrokeGeometry.rounded(point)
        let offset = Point(x: target.x - anchors[index].x, y: target.y - anchors[index].y)
        shape.anchors[index] = target
        if outline == .curve, var handles {
            let count = anchors.count
            let outgoing = index * 2
            let incoming = ((index + count - 1) % count) * 2 + 1
            for handle in [outgoing, incoming] where handles.indices.contains(handle) {
                handles[handle] = StrokeGeometry.rounded(Point(x: handles[handle].x + offset.x, y: handles[handle].y + offset.y))
            }
            shape.handles = handles
        }
        if outline == .polygon {
            shape = shape.clampingRadii()
        }
        return shape
    }

    public func movingHandle(_ index: Int, to point: Point) -> ShapeGeometry {
        guard outline == .curve, var handles, handles.indices.contains(index) else { return self }
        var shape = self
        handles[index] = StrokeGeometry.rounded(point)
        shape.handles = handles
        return shape
    }

    public func handleAnchor(_ index: Int) -> Int {
        index % 2 == 0 ? index / 2 : (index / 2 + 1) % max(1, anchors.count)
    }

    private func clampingRadii() -> ShapeGeometry {
        guard let radii else { return self }
        var shape = self
        shape.radii = radii.indices.map { min(radii[$0], maximumRadius(at: $0)) }
        return shape
    }

    public func mapped(_ transform: (Point) -> Point, radiusFactor: Double = 1) -> ShapeGeometry {
        var shape = self
        shape.anchors = anchors.map { StrokeGeometry.rounded(transform($0)) }
        shape.handles = handles?.map { StrokeGeometry.rounded(transform($0)) }
        shape.radii = radii?.map { $0 * radiusFactor }
        return shape
    }
}

public enum ShapeRecognizer {
    public static let minimumSize = 8.0
    public static let closingShare = 0.22
    public static let minimumPerimeterShare = 1.8
    public static let ellipseMeanDeviation = 0.09
    public static let ellipseLargestDeviation = 0.28
    public static let circleRatio = 0.12
    public static let simplifyShare = 0.055
    public static let straightCornerDegrees = 150.0
    public static let shortEdgeShare = 0.06
    public static let rightAngleTolerance = 16.0
    public static let parallelTolerance = 12.0
    public static let axisSnapDegrees = 8.0
    public static let polygonNames = [3: "triangle", 4: "quadrilateral", 5: "pentagon", 6: "hexagon", 7: "heptagon", 8: "octagon"]

    public static func recognize(_ points: [Point]) -> ShapeGeometry? {
        guard points.count >= 8 else { return nil }
        let xs = points.map(\.x)
        let ys = points.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return nil }
        let width = maxX - minX
        let height = maxY - minY
        let diagonal = (width * width + height * height).squareRoot()
        guard diagonal >= minimumSize, let first = points.first, let last = points.last else { return nil }
        let perimeter = zip(points, points.dropFirst()).reduce(0) { $0 + StrokeGeometry.distance($1.0, $1.1) }
        guard StrokeGeometry.distance(first, last) <= diagonal * closingShare, perimeter >= diagonal * minimumPerimeterShare else { return nil }
        var closed = points
        if first != last {
            closed.append(first)
        }
        if let ellipse = ellipse(closed, minX: minX, maxX: maxX, minY: minY, maxY: maxY) {
            return ellipse
        }
        return polygon(closed, diagonal: diagonal, perimeter: perimeter)
    }

    private static func ellipse(_ points: [Point], minX: Double, maxX: Double, minY: Double, maxY: Double) -> ShapeGeometry? {
        let radiusX = (maxX - minX) / 2
        let radiusY = (maxY - minY) / 2
        guard radiusX > 0, radiusY > 0 else { return nil }
        let centre = Point(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
        let deviations = points.map { point -> Double in
            let x = (point.x - centre.x) / radiusX
            let y = (point.y - centre.y) / radiusY
            return abs((x * x + y * y).squareRoot() - 1)
        }
        let mean = deviations.reduce(0, +) / Double(deviations.count)
        guard mean <= ellipseMeanDeviation, (deviations.max() ?? 1) <= ellipseLargestDeviation else { return nil }
        if abs(radiusX - radiusY) / max(radiusX, radiusY) <= circleRatio {
            let radius = (radiusX + radiusY) / 2
            return .ellipse("circle", center: centre, radiusX: radius, radiusY: radius)
        }
        return .ellipse("ellipse", center: centre, radiusX: radiusX, radiusY: radiusY)
    }

    private static func polygon(_ closed: [Point], diagonal: Double, perimeter: Double) -> ShapeGeometry? {
        guard let start = closed.first else { return nil }
        let farthest = closed.indices.max { StrokeGeometry.distance(closed[$0], start) < StrokeGeometry.distance(closed[$1], start) } ?? 0
        guard farthest > 0, farthest < closed.count - 1 else { return nil }
        let tolerance = diagonal * simplifyShare
        let firstHalf = Ink.simplified(Array(closed[0...farthest]), tolerance: tolerance)
        let secondHalf = Ink.simplified(Array(closed[farthest...]), tolerance: tolerance)
        var corners = Array(firstHalf.dropLast()) + Array(secondHalf.dropLast())
        corners = merged(corners, minimumEdge: perimeter * shortEdgeShare)
        guard let name = polygonNames[corners.count] else { return nil }
        if corners.count == 4 {
            if isRectangle(corners) {
                return .polygon("rectangle", rectangle(corners))
            }
            if let trapezoid = trapezoid(corners) {
                return .polygon("trapezoid", trapezoid)
            }
        }
        return .polygon(name, corners)
    }

    private static func cornerAngle(_ corners: [Point], _ index: Int) -> Double {
        let count = corners.count
        return angle(at: corners[index], corners[(index + count - 1) % count], corners[(index + 1) % count])
    }

    private static func merged(_ points: [Point], minimumEdge: Double) -> [Point] {
        var corners = points
        while corners.count > 3 {
            if let straight = corners.indices.first(where: { cornerAngle(corners, $0) > straightCornerDegrees }) {
                corners.remove(at: straight)
                continue
            }
            guard let short = corners.indices.first(where: { StrokeGeometry.distance(corners[$0], corners[($0 + 1) % corners.count]) < minimumEdge }) else { break }
            let next = (short + 1) % corners.count
            corners.remove(at: cornerAngle(corners, short) > cornerAngle(corners, next) ? short : next)
        }
        return corners
    }

    static func angle(at point: Point, _ previous: Point, _ next: Point) -> Double {
        let first = Point(x: previous.x - point.x, y: previous.y - point.y)
        let second = Point(x: next.x - point.x, y: next.y - point.y)
        let lengths = (first.x * first.x + first.y * first.y).squareRoot() * (second.x * second.x + second.y * second.y).squareRoot()
        guard lengths > 1e-9 else { return 180 }
        return acos(max(-1, min(1, (first.x * second.x + first.y * second.y) / lengths))) * 180 / Double.pi
    }

    private static func isRectangle(_ corners: [Point]) -> Bool {
        corners.indices.allSatisfy { index in
            let count = corners.count
            return abs(angle(at: corners[index], corners[(index + count - 1) % count], corners[(index + 1) % count]) - 90) <= rightAngleTolerance
        }
    }

    private static func direction(_ start: Point, _ end: Point) -> Double {
        atan2(end.y - start.y, end.x - start.x)
    }

    private static func rectangle(_ corners: [Point]) -> [Point] {
        let edges = corners.indices.map { (corners[$0], corners[($0 + 1) % corners.count]) }
        let longest = edges.max { StrokeGeometry.distance($0.0, $0.1) < StrokeGeometry.distance($1.0, $1.1) } ?? edges[0]
        var heading = direction(longest.0, longest.1)
        let quarter = Double.pi / 2
        let snapped = (heading / quarter).rounded() * quarter
        if abs(heading - snapped) * 180 / Double.pi <= axisSnapDegrees {
            heading = snapped
        }
        let along = Point(x: cos(heading), y: sin(heading))
        let across = Point(x: -along.y, y: along.x)
        let projections = corners.map { (u: $0.x * along.x + $0.y * along.y, v: $0.x * across.x + $0.y * across.y) }
        let lowU = projections.map(\.u).min() ?? 0
        let highU = projections.map(\.u).max() ?? 0
        let lowV = projections.map(\.v).min() ?? 0
        let highV = projections.map(\.v).max() ?? 0
        func point(_ u: Double, _ v: Double) -> Point {
            Point(x: along.x * u + across.x * v, y: along.y * u + across.y * v)
        }
        let rectangle = [point(lowU, lowV), point(highU, lowV), point(highU, highV), point(lowU, highV)]
        let start = rectangle.indices.min { StrokeGeometry.distance(rectangle[$0], corners[0]) < StrokeGeometry.distance(rectangle[$1], corners[0]) } ?? 0
        let ordered = (0..<4).map { rectangle[(start + $0) % 4] }
        return isClockwise(ordered) == isClockwise(corners) ? ordered : [ordered[0], ordered[3], ordered[2], ordered[1]]
    }

    private static func isClockwise(_ points: [Point]) -> Bool {
        points.indices.reduce(0.0) { total, index in
            let next = points[(index + 1) % points.count]
            return total + (next.x - points[index].x) * (next.y + points[index].y)
        } < 0
    }

    private static func trapezoid(_ corners: [Point]) -> [Point]? {
        for pair in [(0, 2), (1, 3)] {
            let first = (corners[pair.0], corners[(pair.0 + 1) % 4])
            let second = (corners[pair.1], corners[(pair.1 + 1) % 4])
            var difference = abs(direction(first.0, first.1) - direction(second.1, second.0))
            while difference > Double.pi {
                difference = abs(difference - 2 * Double.pi)
            }
            guard difference * 180 / Double.pi <= parallelTolerance else { continue }
            let firstLength = StrokeGeometry.distance(first.0, first.1)
            let secondLength = StrokeGeometry.distance(second.0, second.1)
            let heading = firstLength >= secondLength ? direction(first.0, first.1) : direction(second.1, second.0)
            let along = Point(x: cos(heading), y: sin(heading))
            var result = corners
            for edge in [pair.0, pair.1] {
                let start = corners[edge]
                let end = corners[(edge + 1) % 4]
                let middle = Point(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
                for (position, point) in [(edge, start), ((edge + 1) % 4, end)] {
                    let reach = (point.x - middle.x) * along.x + (point.y - middle.y) * along.y
                    result[position] = Point(x: middle.x + along.x * reach, y: middle.y + along.y * reach)
                }
            }
            return result
        }
        return nil
    }
}
