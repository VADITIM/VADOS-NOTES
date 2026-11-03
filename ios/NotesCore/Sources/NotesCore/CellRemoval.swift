import Foundation

public enum CellAxis: Equatable, Sendable {
    case columns
    case rows

    public var cellSize: Double {
        self == .columns ? PaperGeometry.cellWidth : PaperGeometry.cellHeight
    }
}

public extension Extent {
    func count(along axis: CellAxis) -> Int {
        axis == .columns ? columns : rows
    }

    func adding(_ axis: CellAxis) -> Extent {
        axis == .columns ? Extent(columns: columns + 1, rows: rows) : Extent(columns: columns, rows: rows + 1)
    }

    func removing(_ axis: CellAxis) -> Extent {
        axis == .columns ? Extent(columns: max(1, columns - 1), rows: rows) : Extent(columns: columns, rows: max(1, rows - 1))
    }

    func cell(containing point: Point, along axis: CellAxis) -> Int {
        let position = axis == .columns ? point.x : point.y
        return min(count(along: axis) - 1, max(0, Int((position / axis.cellSize).rounded(.down))))
    }
}

public enum CellRemoval {
    public struct Outcome: Equatable {
        public var removed: [Element]
        public var moved: [Element]
    }

    public static func outcome(of elements: [Element], removing index: Int, along axis: CellAxis, centre: (Element) -> Point?) -> Outcome {
        var outcome = Outcome(removed: [], moved: [])
        let start = Double(index) * axis.cellSize
        let end = start + axis.cellSize
        let shift = axis == .columns ? Point(x: -axis.cellSize, y: 0) : Point(x: 0, y: -axis.cellSize)
        for element in elements where !element.deleted {
            guard let point = centre(element) else { continue }
            let position = axis == .columns ? point.x : point.y
            if position >= start && position < end {
                outcome.removed.append(element)
            } else if position >= end {
                outcome.moved.append(Lasso.translated(element, by: shift))
            }
        }
        return outcome
    }
}
