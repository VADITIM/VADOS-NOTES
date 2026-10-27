import Foundation

public enum Lasso {
    public static let enclosedShare = 0.5

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

    public static func encloses(_ polygon: [Point], points: [Point]) -> Bool {
        guard !points.isEmpty else { return false }
        let inside = points.filter { contains(polygon, $0) }.count
        return Double(inside) >= Double(points.count) * enclosedShare
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
