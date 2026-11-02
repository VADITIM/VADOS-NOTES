import Foundation

public struct CellIndex: Hashable, Sendable {
    public let column: Int
    public let row: Int

    public init(column: Int, row: Int) {
        self.column = column
        self.row = row
    }

    func contains(_ point: Point) -> Bool {
        let left = Double(column) * PaperGeometry.cellWidth
        let top = Double(row) * PaperGeometry.cellHeight
        return point.x >= left && point.x < left + PaperGeometry.cellWidth && point.y >= top && point.y < top + PaperGeometry.cellHeight
    }
}

public enum CellSwap {
    public static func moved(_ elements: [Element], swapping first: CellIndex, with second: CellIndex, centre: (Element) -> Point?) -> [Element] {
        guard first != second else { return [] }
        let offset = Point(x: Double(second.column - first.column) * PaperGeometry.cellWidth, y: Double(second.row - first.row) * PaperGeometry.cellHeight)
        var moved: [Element] = []
        for element in elements where !element.deleted {
            guard let point = centre(element) else { continue }
            if first.contains(point) {
                moved.append(Lasso.translated(element, by: offset))
            } else if second.contains(point) {
                moved.append(Lasso.translated(element, by: Point(x: -offset.x, y: -offset.y)))
            }
        }
        return moved
    }
}
