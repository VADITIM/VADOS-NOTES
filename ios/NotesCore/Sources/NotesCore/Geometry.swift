import Foundation

public enum PaperGeometry {
    public static let cellWidth = 210.0
    public static let cellHeight = 297.0
    public static let gridSpacing = 5.0

    public static func width(of extent: Extent) -> Double {
        Double(extent.columns) * cellWidth
    }

    public static func height(of extent: Extent) -> Double {
        Double(extent.rows) * cellHeight
    }
}

public enum StrokeGeometry {
    public static let minimumPointSpacing = 0.15
    public static let pointPrecision = 100.0

    public static func rounded(_ point: Point) -> Point {
        Point(x: (point.x * pointPrecision).rounded() / pointPrecision, y: (point.y * pointPrecision).rounded() / pointPrecision)
    }

    public static func shouldAppend(_ point: Point, after previous: Point?) -> Bool {
        guard let previous else { return true }
        return distance(point, previous) >= minimumPointSpacing
    }

    public static func distance(_ first: Point, _ second: Point) -> Double {
        let horizontal = first.x - second.x
        let vertical = first.y - second.y
        return (horizontal * horizontal + vertical * vertical).squareRoot()
    }

    public static func distance(from point: Point, toSegmentFrom start: Point, to end: Point) -> Double {
        let segmentX = end.x - start.x
        let segmentY = end.y - start.y
        let lengthSquared = segmentX * segmentX + segmentY * segmentY
        guard lengthSquared > 0 else { return distance(point, start) }
        let projection = ((point.x - start.x) * segmentX + (point.y - start.y) * segmentY) / lengthSquared
        let clamped = min(1, max(0, projection))
        return distance(point, Point(x: start.x + clamped * segmentX, y: start.y + clamped * segmentY))
    }

    public static func isHit(_ element: Element, by point: Point, radius: Double) -> Bool {
        guard element.type == .stroke, !element.deleted, let points = element.points, let first = points.first else { return false }
        let reach = radius + (element.width ?? 0) / 2
        if points.count == 1 {
            return distance(point, first) <= reach
        }
        for index in 1..<points.count where distance(from: point, toSegmentFrom: points[index - 1], to: points[index]) <= reach {
            return true
        }
        return false
    }

    public static func bounds(of points: [Point]) -> (minimumX: Double, minimumY: Double, maximumX: Double, maximumY: Double)? {
        guard let first = points.first else { return nil }
        var bounds = (minimumX: first.x, minimumY: first.y, maximumX: first.x, maximumY: first.y)
        for point in points {
            bounds.minimumX = min(bounds.minimumX, point.x)
            bounds.minimumY = min(bounds.minimumY, point.y)
            bounds.maximumX = max(bounds.maximumX, point.x)
            bounds.maximumY = max(bounds.maximumY, point.y)
        }
        return bounds
    }
}
