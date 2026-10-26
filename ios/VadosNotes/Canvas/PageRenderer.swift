import NotesCore
import UIKit

struct CanvasCamera: Equatable {
    var scale: CGFloat = 3
    var offset: CGPoint = .zero

    static let minimumScale: CGFloat = 0.6
    static let maximumScale: CGFloat = 40

    func toScreen(_ point: Point) -> CGPoint {
        CGPoint(x: CGFloat(point.x) * scale + offset.x, y: CGFloat(point.y) * scale + offset.y)
    }

    func toPage(_ point: CGPoint) -> Point {
        Point(x: Double((point.x - offset.x) / scale), y: Double((point.y - offset.y) / scale))
    }

    func toScreen(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX * scale + offset.x, y: rect.minY * scale + offset.y, width: rect.width * scale, height: rect.height * scale)
    }

    func toPage(_ rect: CGRect) -> CGRect {
        CGRect(x: (rect.minX - offset.x) / scale, y: (rect.minY - offset.y) / scale, width: rect.width / scale, height: rect.height / scale)
    }

    static func fitting(_ extent: Extent, in bounds: CGSize, margin: CGFloat) -> CanvasCamera {
        let width = CGFloat(PaperGeometry.cellWidth)
        let height = CGFloat(PaperGeometry.cellHeight)
        let available = CGSize(width: max(1, bounds.width - margin * 2), height: max(1, bounds.height - margin * 2))
        let scale = min(available.width / width, available.height / height)
        let shownWidth = CGFloat(extent.columns) * width * scale
        let horizontalOffset = shownWidth < bounds.width ? (bounds.width - shownWidth) / 2 : margin
        return CanvasCamera(scale: scale, offset: CGPoint(x: horizontalOffset, y: margin))
    }

    func zoomed(by factor: CGFloat, around anchor: CGPoint) -> CanvasCamera {
        let newScale = min(Self.maximumScale, max(Self.minimumScale, scale * factor))
        let pagePoint = toPage(anchor)
        return CanvasCamera(scale: newScale, offset: CGPoint(x: anchor.x - CGFloat(pagePoint.x) * newScale, y: anchor.y - CGFloat(pagePoint.y) * newScale))
    }
}

enum InkStyle {
    static func tokens(for tool: Tool) -> Tokens.InkToolTokens {
        switch tool {
        case .pen: return Tokens.shared.tools.pen
        case .pencil: return Tokens.shared.tools.pencil
        case .marker: return Tokens.shared.tools.marker
        }
    }

    static func color(for element: Element) -> UIColor {
        let base = UIColor(hex: element.color ?? "#1A1A1A")
        guard let tool = element.tool else { return base }
        return base.withAlphaComponent(CGFloat(tokens(for: tool).opacity))
    }
}

final class StrokePathCache {
    private struct Entry {
        let updated: Date
        let path: CGPath
        let bounds: CGRect
    }

    private var entries: [String: Entry] = [:]

    func path(for element: Element) -> (path: CGPath, bounds: CGRect) {
        if let entry = entries[element.id], entry.updated == element.updated {
            return (entry.path, entry.bounds)
        }
        let path = Self.makePath(element.points ?? [])
        let inset = -CGFloat(element.width ?? 1)
        let bounds = path.boundingBoxOfPath.insetBy(dx: inset, dy: inset)
        entries[element.id] = Entry(updated: element.updated, path: path, bounds: bounds)
        return (path, bounds)
    }

    static func makePath(_ points: [Point], transform: (Point) -> CGPoint = { CGPoint(x: $0.x, y: $0.y) }) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: transform(first))
        if points.count == 1 {
            path.addLine(to: transform(first))
            return path
        }
        if points.count == 2 {
            path.addLine(to: transform(points[1]))
            return path
        }
        for index in 1..<(points.count - 1) {
            let control = transform(points[index])
            let next = transform(points[index + 1])
            path.addQuadCurve(to: CGPoint(x: (control.x + next.x) / 2, y: (control.y + next.y) / 2), control: control)
        }
        path.addLine(to: transform(points[points.count - 1]))
        return path
    }
}

struct RenderOptions {
    var showsGuides = true
    var hiddenElementIds: Set<String> = []
    var textOffsets: [String: CGVector] = [:]
}

enum PageRenderer {
    static func draw(_ page: Page, in context: CGContext, camera: CanvasCamera, visibleRect: CGRect, options: RenderOptions, cache: StrokePathCache) {
        context.setFillColor(Palette.outside.cgColor)
        context.fill(visibleRect)

        let paperRect = CGRect(x: 0, y: 0, width: PaperGeometry.width(of: page.extent), height: PaperGeometry.height(of: page.extent))
        let visiblePage = camera.toPage(visibleRect).intersection(paperRect)
        guard !visiblePage.isNull else { return }

        context.saveGState()
        context.translateBy(x: camera.offset.x, y: camera.offset.y)
        context.scaleBy(x: camera.scale, y: camera.scale)

        context.setFillColor(Palette.paper.cgColor)
        context.fill(paperRect)
        if options.showsGuides {
            drawGuides(in: context, paperRect: paperRect, visiblePage: visiblePage, camera: camera)
        }
        drawCellBoundaries(in: context, extent: page.extent, camera: camera)

        context.clip(to: paperRect)
        for element in page.liveElements where !options.hiddenElementIds.contains(element.id) {
            switch element.type {
            case .stroke:
                drawStroke(element, in: context, visiblePage: visiblePage, cache: cache)
            case .text:
                drawText(element, in: context, offset: options.textOffsets[element.id] ?? .zero)
            case .importPage:
                continue
            }
        }
        context.restoreGState()
    }

    static func textRect(for element: Element) -> CGRect? {
        guard element.type == .text, let box = element.box else { return nil }
        let size = textSize(element)
        return CGRect(x: box.x, y: box.y, width: box.width, height: max(size.height, CGFloat(element.fontSize ?? Tokens.shared.text.fontSize) * 1.4))
    }

    static func textAttributes(fontSize: CGFloat, color: UIColor) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = CGFloat(Tokens.shared.text.lineHeight)
        paragraph.lineBreakMode = .byWordWrapping
        return [.font: Typography.monoFont(fontSize), .foregroundColor: color, .paragraphStyle: paragraph]
    }

    private static func textSize(_ element: Element) -> CGSize {
        let fontSize = CGFloat(element.fontSize ?? Tokens.shared.text.fontSize)
        let width = CGFloat(element.box?.width ?? Tokens.shared.text.boxWidth)
        let content = (element.content ?? "") as NSString
        let bounds = content.boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: textAttributes(fontSize: fontSize, color: .black),
            context: nil
        )
        return CGSize(width: width, height: ceil(bounds.height))
    }

    private static func drawStroke(_ element: Element, in context: CGContext, visiblePage: CGRect, cache: StrokePathCache) {
        let cached = cache.path(for: element)
        guard cached.bounds.intersects(visiblePage) else { return }
        context.saveGState()
        context.addPath(cached.path)
        context.setLineWidth(CGFloat(element.width ?? 0.5))
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setStrokeColor(InkStyle.color(for: element).cgColor)
        context.strokePath()
        context.restoreGState()
    }

    private static func drawText(_ element: Element, in context: CGContext, offset: CGVector) {
        guard let rect = textRect(for: element), let content = element.content, !content.isEmpty else { return }
        let fontSize = CGFloat(element.fontSize ?? Tokens.shared.text.fontSize)
        UIGraphicsPushContext(context)
        (content as NSString).draw(
            with: rect.offsetBy(dx: offset.dx, dy: offset.dy),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: textAttributes(fontSize: fontSize, color: UIColor(hex: element.color ?? Tokens.shared.text.color)),
            context: nil
        )
        UIGraphicsPopContext()
    }

    private static func drawGuides(in context: CGContext, paperRect: CGRect, visiblePage: CGRect, camera: CanvasCamera) {
        let spacing = CGFloat(PaperGeometry.gridSpacing)
        guard spacing * camera.scale >= 4 else { return }
        context.saveGState()
        context.setStrokeColor(Palette.guide.cgColor)
        context.setLineWidth(1 / camera.scale)
        var x = (visiblePage.minX / spacing).rounded(.down) * spacing
        while x <= visiblePage.maxX {
            context.move(to: CGPoint(x: x, y: visiblePage.minY))
            context.addLine(to: CGPoint(x: x, y: visiblePage.maxY))
            x += spacing
        }
        var y = (visiblePage.minY / spacing).rounded(.down) * spacing
        while y <= visiblePage.maxY {
            context.move(to: CGPoint(x: visiblePage.minX, y: y))
            context.addLine(to: CGPoint(x: visiblePage.maxX, y: y))
            y += spacing
        }
        context.strokePath()
        context.restoreGState()
    }

    private static func drawCellBoundaries(in context: CGContext, extent: Extent, camera: CanvasCamera) {
        guard extent.cellCount > 1 else { return }
        let width = CGFloat(PaperGeometry.cellWidth)
        let height = CGFloat(PaperGeometry.cellHeight)
        context.saveGState()
        context.setStrokeColor(Palette.cellBoundary.cgColor)
        context.setLineWidth(1.5 / camera.scale)
        context.setLineDash(phase: 0, lengths: [6 / camera.scale, 4 / camera.scale])
        for column in 1..<max(2, extent.columns) where column < extent.columns {
            context.move(to: CGPoint(x: CGFloat(column) * width, y: 0))
            context.addLine(to: CGPoint(x: CGFloat(column) * width, y: CGFloat(extent.rows) * height))
        }
        for row in 1..<max(2, extent.rows) where row < extent.rows {
            context.move(to: CGPoint(x: 0, y: CGFloat(row) * height))
            context.addLine(to: CGPoint(x: CGFloat(extent.columns) * width, y: CGFloat(row) * height))
        }
        context.strokePath()
        context.restoreGState()
    }

    static func thumbnail(of page: Page, size: CGSize, showsGuides: Bool) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        let cache = StrokePathCache()
        return renderer.image { rendererContext in
            let width = PaperGeometry.width(of: page.extent)
            let height = PaperGeometry.height(of: page.extent)
            let scale = min(size.width / width, size.height / height)
            let offset = CGPoint(x: (size.width - width * scale) / 2, y: (size.height - height * scale) / 2)
            let camera = CanvasCamera(scale: scale, offset: offset)
            draw(page, in: rendererContext.cgContext, camera: camera, visibleRect: CGRect(origin: .zero, size: size), options: RenderOptions(showsGuides: showsGuides), cache: cache)
        }
    }
}
