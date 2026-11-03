import Foundation

public struct ElementEdit: Equatable, Sendable {
    public var before: [Element]
    public var after: [Element]

    public init(before: [Element] = [], after: [Element] = []) {
        self.before = before
        self.after = after
    }

    public func reversal(current: (String) -> Element?, now: Date, device: String, newIdentifier: () -> String) -> ElementEdit {
        let beforeById = Dictionary(before.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var reverse = ElementEdit()
        for after in after {
            let present = current(after.id) ?? after
            if let before = beforeById[after.id] {
                if after.deleted && !before.deleted {
                    var revived = before
                    revived.id = newIdentifier()
                    revived.updated = now
                    revived.device = device
                    revived.deleted = false
                    reverse.after.append(revived)
                } else if !after.deleted {
                    var restored = before
                    restored.updated = now
                    restored.device = device
                    reverse.before.append(present)
                    reverse.after.append(restored)
                }
            } else if !present.deleted {
                reverse.before.append(present)
                reverse.after.append(present.tombstone(at: now, device: device))
            }
        }
        return reverse
    }
}

public enum ImportPlacing {
    public static func cell(of element: Element) -> CellIndex? {
        guard let placement = element.placement, let size = element.sourceSizeMillimetres, size.count == 2 else { return nil }
        let x = placement.x + size[0] * placement.scale / 2
        let y = placement.y + size[1] * placement.scale / 2
        return CellIndex(column: Int((x / PaperGeometry.cellWidth).rounded(.down)), row: Int((y / PaperGeometry.cellHeight).rounded(.down)))
    }

    public static func isPlaced(asset: String, sourcePage: Int, in elements: [Element]) -> Bool {
        elements.contains { isSource($0, asset: asset, sourcePage: sourcePage) }
    }

    public static func placed(asset: String, sourcePage: Int, at target: CellIndex, in elements: [Element], now: Date, device: String, adding: () -> Element) -> ElementEdit {
        let imports = elements.filter { !$0.deleted && $0.type == .importPage }
        let isSame: (Element) -> Bool = { isSource($0, asset: asset, sourcePage: sourcePage) }
        guard !imports.contains(where: { isSame($0) && cell(of: $0) == target }) else { return ElementEdit() }
        var edit = ElementEdit()
        for occupant in imports where !isSame(occupant) && cell(of: occupant) == target {
            edit.before.append(occupant)
            edit.after.append(occupant.tombstone(at: now, device: device))
        }
        if let existing = imports.first(where: isSame), let origin = cell(of: existing) {
            let offset = Point(x: Double(target.column - origin.column) * PaperGeometry.cellWidth, y: Double(target.row - origin.row) * PaperGeometry.cellHeight)
            var moved = Lasso.translated(existing, by: offset)
            moved.updated = now
            moved.device = device
            edit.before.append(existing)
            edit.after.append(moved)
        } else {
            edit.after.append(adding())
        }
        return edit
    }

    private static func isSource(_ element: Element, asset: String, sourcePage: Int) -> Bool {
        !element.deleted && element.type == .importPage && element.asset == asset && (element.sourcePage ?? 0) == sourcePage
    }
}
