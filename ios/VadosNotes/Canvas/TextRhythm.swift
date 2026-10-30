import NotesCore
import UIKit

enum TextRhythm {
    private static var offsets: [String: CGFloat] = [:]

    static var rowGap: CGFloat {
        CGFloat(PaperGeometry.rowSpacing)
    }

    static var fontSize: CGFloat {
        let unit = MarkdownText.font(1, isBold: false)
        return rowGap / (unit.ascender - unit.descender + unit.leading)
    }

    static var baseline: CGFloat {
        MarkdownText.font(fontSize, isBold: false).ascender
    }

    static func rows(for scale: Double) -> Int {
        max(1, Int(scale.rounded(.up)))
    }

    static func paragraph(rows: Int, zoom: CGFloat) -> NSMutableParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        let height = rowGap * CGFloat(rows) * zoom
        paragraph.minimumLineHeight = height
        paragraph.maximumLineHeight = height
        paragraph.lineBreakMode = .byWordWrapping
        return paragraph
    }

    static func baselineOffset(font: UIFont, rows: Int, zoom: CGFloat) -> CGFloat {
        let key = "\(font.fontName)|\(font.pointSize)|\(rows)|\(zoom)"
        if let cached = offsets[key] {
            return cached
        }
        let storage = NSTextStorage(string: "0", attributes: [.font: font, .paragraphStyle: paragraph(rows: rows, zoom: zoom)])
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        let placed = manager.location(forGlyphAt: 0).y
        let target = (baseline + rowGap * CGFloat(rows - 1)) * zoom
        if offsets.count > 500 {
            offsets.removeAll()
        }
        offsets[key] = placed - target
        return placed - target
    }

    static func attributes(zoom: CGFloat, color: UIColor) -> [NSAttributedString.Key: Any] {
        let font = MarkdownText.font(fontSize * zoom, isBold: false)
        return [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph(rows: 1, zoom: zoom),
            .baselineOffset: baselineOffset(font: font, rows: 1, zoom: zoom),
        ]
    }

    static func snappedTop(_ top: Double) -> Double {
        let gap = Double(rowGap)
        let lift = Double(baseline)
        return ((top + lift) / gap).rounded() * gap - lift
    }

    static func placed(_ box: TextBox, extent: Extent, height: Double) -> TextBox {
        let gap = Double(rowGap)
        let clamped = Ink.clampBox(box, extent: extent, height: height)
        var top = snappedTop(clamped.y)
        if top < 0 {
            top += gap
        }
        if top + height > PaperGeometry.height(of: extent), top - gap >= 0 {
            top -= gap
        }
        return TextBox(x: clamped.x, y: top, width: clamped.width)
    }

    static func fitted(_ element: Element, extent: Extent) -> Element {
        guard element.type == .text, let box = element.box else { return element }
        var fitted = element
        fitted.fontSize = Double(fontSize)
        let height = Double(PageRenderer.textRect(for: element)?.height ?? rowGap)
        fitted.box = placed(box, extent: extent, height: height)
        return fitted
    }
}
