import Foundation

public struct InkSettings: Equatable, Sendable {
    public var sampleSpacing: Double
    public var smoothing: Double
    public var simplify: Double
    public var axisSnapDegrees: Double

    public init(sampleSpacing: Double, smoothing: Double, simplify: Double, axisSnapDegrees: Double) {
        self.sampleSpacing = sampleSpacing
        self.smoothing = smoothing
        self.simplify = simplify
        self.axisSnapDegrees = axisSnapDegrees
    }
}

public enum Ink {
    private static let boundaryIterations = 30
    private static let smoothingReach = 2.5

    static func point(from start: Point, to end: Point, share: Double) -> Point {
        Point(x: start.x + (end.x - start.x) * share, y: start.y + (end.y - start.y) * share)
    }

    static func length(of points: [Point]) -> Double {
        guard points.count > 1 else { return 0 }
        return (1..<points.count).reduce(0) { $0 + StrokeGeometry.distance(points[$1 - 1], points[$1]) }
    }

    static func evenlySpaced(_ points: [Point], spacing: Double) -> [Point] {
        guard points.count > 1 else { return points }
        var result = [points[0]]
        var carried = 0.0
        for index in 1..<points.count {
            let start = points[index - 1]
            let end = points[index]
            let segment = StrokeGeometry.distance(start, end)
            var travelled = spacing - carried
            while travelled <= segment {
                result.append(point(from: start, to: end, share: travelled / segment))
                travelled += spacing
            }
            carried = segment - (travelled - spacing)
        }
        let last = points[points.count - 1]
        if StrokeGeometry.distance(result[result.count - 1], last) > spacing * 0.05 {
            result.append(last)
        } else {
            result[result.count - 1] = last
        }
        return result
    }

    static func gaussianSmoothed(_ points: [Point], sigmaSamples: Double) -> [Point] {
        guard points.count >= 3, sigmaSamples > 0 else { return points }
        let reach = Int((sigmaSamples * smoothingReach).rounded(.up))
        let weights = (0...reach).map { offset in exp(-Double(offset * offset) / (2 * sigmaSamples * sigmaSamples)) }
        let last = points.count - 1
        return points.indices.map { index in
            let window = min(reach, index, last - index)
            guard window > 0 else { return points[index] }
            var x = points[index].x * weights[0]
            var y = points[index].y * weights[0]
            var total = weights[0]
            for offset in 1...window {
                let weight = weights[offset]
                x += (points[index - offset].x + points[index + offset].x) * weight
                y += (points[index - offset].y + points[index + offset].y) * weight
                total += weight * 2
            }
            return Point(x: x / total, y: y / total)
        }
    }

    static func simplified(_ points: [Point], tolerance: Double) -> [Point] {
        guard points.count >= 3 else { return points }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        var ranges = [(0, points.count - 1)]
        while let range = ranges.popLast() {
            let (first, last) = range
            var farthest = -1
            var farthestDistance = tolerance
            if last - first > 1 {
                for index in (first + 1)..<last {
                    let candidate = StrokeGeometry.distance(from: points[index], toSegmentFrom: points[first], to: points[last])
                    if candidate > farthestDistance {
                        farthest = index
                        farthestDistance = candidate
                    }
                }
            }
            if farthest >= 0 {
                keep[farthest] = true
                ranges.append((first, farthest))
                ranges.append((farthest, last))
            }
        }
        return points.indices.filter { keep[$0] }.map { points[$0] }
    }

    public static func cleaned(_ points: [Point]) -> [Point] {
        var rounded: [Point] = []
        for point in points {
            let next = StrokeGeometry.rounded(point)
            if rounded.last != next {
                rounded.append(next)
            }
        }
        return rounded
    }

    public static func smoothStroke(_ points: [Point], scale: Double, settings: InkSettings) -> [Point] {
        guard points.count >= 3 else { return cleaned(points) }
        let even = evenlySpaced(points, spacing: settings.sampleSpacing / scale)
        let smooth = gaussianSmoothed(even, sigmaSamples: settings.smoothing / settings.sampleSpacing)
        return cleaned(simplified(smooth, tolerance: settings.simplify / scale))
    }

    public static func axisSnapped(start: Point, end: Point, degrees: Double) -> Point {
        let deltaX = end.x - start.x
        let deltaY = end.y - start.y
        let tolerance = tan(degrees * .pi / 180)
        if abs(deltaY) <= abs(deltaX) * tolerance {
            return Point(x: end.x, y: start.y)
        }
        if abs(deltaX) <= abs(deltaY) * tolerance {
            return Point(x: start.x, y: end.y)
        }
        return end
    }

    public static func straightened(_ points: [Point], start: Point, end: Point, share: Double) -> [Point] {
        let total = length(of: points)
        guard total > 0, share < 1 else { return [start, end] }
        var travelled = 0.0
        return points.indices.map { index in
            if index > 0 {
                travelled += StrokeGeometry.distance(points[index - 1], points[index])
            }
            let target = point(from: start, to: end, share: travelled / total)
            return point(from: points[index], to: target, share: share)
        }
    }

    static func segmentsCross(_ first: Point, _ second: Point, _ third: Point, _ fourth: Point) -> Bool {
        func side(_ origin: Point, _ toward: Point, _ point: Point) -> Double {
            (toward.x - origin.x) * (point.y - origin.y) - (toward.y - origin.y) * (point.x - origin.x)
        }
        return side(third, fourth, first) * side(third, fourth, second) < 0 && side(first, second, third) * side(first, second, fourth) < 0
    }

    static func segmentDistance(_ start: Point, _ end: Point, _ sweepStart: Point, _ sweepEnd: Point) -> Double {
        if segmentsCross(start, end, sweepStart, sweepEnd) {
            return 0
        }
        return min(
            StrokeGeometry.distance(from: start, toSegmentFrom: sweepStart, to: sweepEnd),
            StrokeGeometry.distance(from: end, toSegmentFrom: sweepStart, to: sweepEnd),
            StrokeGeometry.distance(from: sweepStart, toSegmentFrom: start, to: end),
            StrokeGeometry.distance(from: sweepEnd, toSegmentFrom: start, to: end)
        )
    }

    public static func isStrokeSwept(_ element: Element, from sweepStart: Point, to sweepEnd: Point, radius: Double) -> Bool {
        guard element.type == .stroke, !element.deleted, let points = element.points, let first = points.first else { return false }
        let reach = radius + (element.width ?? 0) / 2
        if points.count == 1 {
            return StrokeGeometry.distance(from: first, toSegmentFrom: sweepStart, to: sweepEnd) <= reach
        }
        for index in 1..<points.count where segmentDistance(points[index - 1], points[index], sweepStart, sweepEnd) <= reach {
            return true
        }
        return false
    }

    static func insideInterval(_ start: Point, _ end: Point, _ sweepStart: Point, _ sweepEnd: Point, reach: Double) -> (Double, Double)? {
        guard segmentDistance(start, end, sweepStart, sweepEnd) <= reach else { return nil }
        func gap(_ share: Double) -> Double {
            StrokeGeometry.distance(from: point(from: start, to: end, share: share), toSegmentFrom: sweepStart, to: sweepEnd)
        }
        var low = 0.0
        var high = 1.0
        for _ in 0..<boundaryIterations {
            let first = low + (high - low) / 3
            let second = high - (high - low) / 3
            if gap(first) < gap(second) {
                high = second
            } else {
                low = first
            }
        }
        let closest = (low + high) / 2
        guard gap(closest) <= reach else { return nil }
        func boundary(_ outsideStart: Double, _ insideStart: Double) -> Double {
            if gap(outsideStart) <= reach {
                return outsideStart
            }
            var outside = outsideStart
            var inside = insideStart
            for _ in 0..<boundaryIterations {
                let middle = (outside + inside) / 2
                if gap(middle) <= reach {
                    inside = middle
                } else {
                    outside = middle
                }
            }
            return (outside + inside) / 2
        }
        return (boundary(0, closest), boundary(1, closest))
    }

    public static func cutStroke(_ points: [Point], from sweepStart: Point, to sweepEnd: Point, reach: Double) -> [[Point]]? {
        guard let first = points.first else { return nil }
        if points.count == 1 {
            return StrokeGeometry.distance(from: first, toSegmentFrom: sweepStart, to: sweepEnd) <= reach ? [] : nil
        }
        var pieces: [[Point]] = []
        var current: [Point] = StrokeGeometry.distance(from: first, toSegmentFrom: sweepStart, to: sweepEnd) <= reach ? [] : [first]
        var isTouched = false
        for index in 1..<points.count {
            let start = points[index - 1]
            let end = points[index]
            guard let interval = insideInterval(start, end, sweepStart, sweepEnd, reach: reach) else {
                if current.isEmpty {
                    current.append(start)
                }
                current.append(end)
                continue
            }
            isTouched = true
            let (entry, exit) = interval
            if entry > 0 {
                if current.isEmpty {
                    current.append(start)
                }
                current.append(point(from: start, to: end, share: entry))
            }
            if !current.isEmpty {
                pieces.append(current)
            }
            current = exit < 1 ? [point(from: start, to: end, share: exit), end] : []
        }
        guard isTouched else { return nil }
        if !current.isEmpty {
            pieces.append(current)
        }
        return pieces.map(cleaned).filter { $0.count >= 2 }
    }

    static func isInside(_ point: Point, width: Double, height: Double) -> Bool {
        point.x >= 0 && point.x <= width && point.y >= 0 && point.y <= height
    }

    static func insideShares(_ start: Point, _ end: Point, width: Double, height: Double) -> (Double, Double)? {
        var entry = 0.0
        var exit = 1.0
        let deltaX = end.x - start.x
        let deltaY = end.y - start.y
        let limits = [(-deltaX, start.x), (deltaX, width - start.x), (-deltaY, start.y), (deltaY, height - start.y)]
        for (direction, room) in limits {
            if direction == 0 {
                if room < 0 {
                    return nil
                }
                continue
            }
            let share = room / direction
            if direction < 0 {
                entry = max(entry, share)
            } else {
                exit = min(exit, share)
            }
            if entry > exit {
                return nil
            }
        }
        return (entry, exit)
    }

    public static func isInsidePaper(_ point: Point, extent: Extent) -> Bool {
        isInside(point, width: PaperGeometry.width(of: extent), height: PaperGeometry.height(of: extent))
    }

    public static func clipToPaper(_ points: [Point], extent: Extent) -> [[Point]] {
        let width = PaperGeometry.width(of: extent)
        let height = PaperGeometry.height(of: extent)
        if points.allSatisfy({ isInside($0, width: width, height: height) }) {
            return [points]
        }
        guard points.count > 1 else { return [] }
        var pieces: [[Point]] = []
        var current: [Point] = []
        for index in 1..<points.count {
            let start = points[index - 1]
            let end = points[index]
            guard let shares = insideShares(start, end, width: width, height: height) else {
                if !current.isEmpty {
                    pieces.append(current)
                    current = []
                }
                continue
            }
            let (entry, exit) = shares
            if current.isEmpty {
                current.append(point(from: start, to: end, share: entry))
            }
            current.append(point(from: start, to: end, share: exit))
            if exit < 1 {
                pieces.append(current)
                current = []
            }
        }
        if !current.isEmpty {
            pieces.append(current)
        }
        return pieces.map(cleaned).filter { $0.count >= 2 }
    }

    public static func clampBox(_ box: TextBox, extent: Extent, height: Double) -> TextBox {
        let paperWidth = PaperGeometry.width(of: extent)
        let paperHeight = PaperGeometry.height(of: extent)
        let width = min(box.width, paperWidth)
        return TextBox(
            x: min(paperWidth - width, max(0, box.x)),
            y: min(paperHeight - height, max(0, box.y)),
            width: width
        )
    }
}

public protocol Arrangeable {
    var id: String { get }
    var order: Int? { get }
}

extension Notebook: Arrangeable {}
extension Page: Arrangeable {}

public enum Arrangement {
    public static func sorted<Item: Arrangeable>(_ items: [Item]) -> [Item] {
        let byIdentifier = items.sorted { $0.id < $1.id }
        var rank: [String: Int] = [:]
        for (index, item) in byIdentifier.enumerated() {
            rank[item.id] = item.order ?? index
        }
        return byIdentifier.sorted { first, second in
            let firstRank = rank[first.id] ?? 0
            let secondRank = rank[second.id] ?? 0
            return firstRank != secondRank ? firstRank < secondRank : first.id < second.id
        }
    }

    public static func endOrder<Item: Arrangeable>(after items: [Item]) -> Int {
        items.enumerated().reduce(-1) { max($0, $1.element.order ?? $1.offset) } + 1
    }
}
