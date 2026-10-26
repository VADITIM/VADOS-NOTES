import Foundation

public enum Merge {
    public static func element(_ first: Element, _ second: Element) -> Element {
        if first.deleted != second.deleted {
            return first.deleted ? first : second
        }
        return isNewer(first.updated, first.device, than: second.updated, second.device) ? first : second
    }

    public static func page(_ first: Page, _ second: Page) -> Page {
        var merged = Page(header: header(first.header, second.header))
        var byId: [String: Element] = [:]
        for element in first.elements {
            byId[element.id] = element
        }
        for element in second.elements {
            if let existing = byId[element.id] {
                byId[element.id] = Merge.element(existing, element)
            } else {
                byId[element.id] = element
            }
        }
        merged.elements = byId.values.sorted(by: Element.isOrderedBefore)
        return merged
    }

    public static func header(_ first: PageHeader, _ second: PageHeader) -> PageHeader {
        let newer = isNewer(first.updated, first.device, than: second.updated, second.device) ? first : second
        return PageHeader(
            schemaVersion: newer.schemaVersion,
            id: newer.id,
            notebook: newer.notebook,
            updated: newer.updated,
            device: newer.device,
            deleted: first.deleted || second.deleted,
            extent: first.extent.union(second.extent)
        )
    }

    public static func notebook(_ first: Notebook, _ second: Notebook) -> Notebook {
        if first.deleted != second.deleted {
            return first.deleted ? first : second
        }
        return isNewer(first.updated, first.device, than: second.updated, second.device) ? first : second
    }

    static func isNewer(_ firstDate: Date, _ firstDevice: String, than secondDate: Date, _ secondDevice: String) -> Bool {
        if firstDate != secondDate {
            return firstDate > secondDate
        }
        return firstDevice >= secondDevice
    }
}
