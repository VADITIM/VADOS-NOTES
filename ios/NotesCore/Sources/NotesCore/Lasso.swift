import Foundation

public enum Lasso {
    public static func contains(_ polygon: [Point], _ point: Point) -> Bool {
        guard polygon.count >= 3 else { return false }
        var isInside = false
        var previous = polygon[polygon.count - 1]
        for current in polygon {
            let crosses = (current.y > point.y) != (previous.y > point.y)
            if crosses {
                let crossingX = current.x + (point.y - current.y) / (previous.y - current.y) * (previous.x - current.x)
                if point.x < crossingX {
                    isInside.toggle()
                }
            }
            previous = current
        }
        return isInside
    }

    public static func touches(_ polygon: [Point], line points: [Point]) -> Bool {
        guard polygon.count >= 3, !points.isEmpty else { return false }
        if points.contains(where: { contains(polygon, $0) }) {
            return true
        }
        return segments(of: points, isClosed: false).contains { segment in
            segments(of: polygon, isClosed: true).contains { crosses(segment, $0) }
        }
    }

    public static func touches(_ polygon: [Point], area corners: [Point]) -> Bool {
        guard polygon.count >= 3, corners.count >= 3 else { return false }
        if corners.contains(where: { contains(polygon, $0) }) || polygon.contains(where: { contains(corners, $0) }) {
            return true
        }
        return segments(of: corners, isClosed: true).contains { segment in
            segments(of: polygon, isClosed: true).contains { crosses(segment, $0) }
        }
    }

    private static func segments(of points: [Point], isClosed: Bool) -> [(Point, Point)] {
        guard points.count >= 2 else { return [] }
        var result = zip(points, points.dropFirst()).map { ($0, $1) }
        if isClosed {
            result.append((points[points.count - 1], points[0]))
        }
        return result
    }

    private static func crosses(_ first: (Point, Point), _ second: (Point, Point)) -> Bool {
        func turn(_ origin: Point, _ end: Point, _ point: Point) -> Double {
            (end.x - origin.x) * (point.y - origin.y) - (end.y - origin.y) * (point.x - origin.x)
        }
        let firstStart = turn(first.0, first.1, second.0)
        let firstEnd = turn(first.0, first.1, second.1)
        let secondStart = turn(second.0, second.1, first.0)
        let secondEnd = turn(second.0, second.1, first.1)
        return firstStart * firstEnd < 0 && secondStart * secondEnd < 0
    }

    public static func translated(_ element: Element, by offset: Point) -> Element {
        var moved = element
        moved.points = element.points?.map { StrokeGeometry.rounded(Point(x: $0.x + offset.x, y: $0.y + offset.y)) }
        if let box = element.box {
            moved.box = TextBox(x: box.x + offset.x, y: box.y + offset.y, width: box.width)
        }
        if let placement = element.placement {
            moved.placement = Placement(x: placement.x + offset.x, y: placement.y + offset.y, scale: placement.scale)
        }
        return moved
    }
}
