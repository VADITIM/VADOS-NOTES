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

    func toPage(_ rect: CGRect) -> CGRect {
        CGRect(x: (rect.minX - offset.x) / scale, y: (rect.minY - offset.y) / scale, width: rect.width / scale, height: rect.height / scale)
    }

    static let panSlackShare: CGFloat = 0.45

    static func fitting(_ extent: Extent, in bounds: CGSize, margin: CGFloat, topInset: CGFloat) -> CanvasCamera {
        let scale = smallestScale(for: extent, in: bounds, margin: margin, topInset: topInset)
        let shownWidth = CGFloat(PaperGeometry.width(of: extent)) * scale
        let shownHeight = CGFloat(PaperGeometry.height(of: extent)) * scale
        return CanvasCamera(scale: scale, offset: CGPoint(x: (bounds.width - shownWidth) / 2, y: (bounds.height - shownHeight) / 2))
    }

    func zoomed(by factor: CGFloat, around anchor: CGPoint) -> CanvasCamera {
        let newScale = min(Self.maximumScale, max(Self.minimumScale, scale * factor))
        let pagePoint = toPage(anchor)
        return CanvasCamera(scale: newScale, offset: CGPoint(x: anchor.x - CGFloat(pagePoint.x) * newScale, y: anchor.y - CGFloat(pagePoint.y) * newScale))
    }

    static func smallestScale(for extent: Extent, in bounds: CGSize, margin: CGFloat, topInset: CGFloat) -> CGFloat {
        let availableWidth = max(1, bounds.width - margin * 2)
        let availableHeight = max(1, bounds.height - (topInset + margin) * 2)
        return min(maximumScale, min(availableWidth / CGFloat(PaperGeometry.width(of: extent)), availableHeight / CGFloat(PaperGeometry.height(of: extent))))
    }

    func constrained(to extent: Extent, in bounds: CGSize, margin: CGFloat, topInset: CGFloat) -> CanvasCamera {
        let paperWidth = CGFloat(PaperGeometry.width(of: extent))
        let paperHeight = CGFloat(PaperGeometry.height(of: extent))
        let smallest = Self.smallestScale(for: extent, in: bounds, margin: margin, topInset: topInset)
        var camera = self
        if camera.scale < smallest {
            camera = camera.zoomed(by: smallest / camera.scale, around: CGPoint(x: bounds.width / 2, y: bounds.height / 2))
        }
        func axis(_ offset: CGFloat, _ size: CGFloat, _ start: CGFloat, _ end: CGFloat, _ slack: CGFloat) -> CGFloat {
            if size <= end - start {
                let centred = start + (end - start - size) / 2
                return min(centred + slack, max(centred - slack, offset))
            }
            return min(start + slack, max(end - size - slack, offset))
        }
        camera.offset.x = axis(camera.offset.x, paperWidth * camera.scale, margin, bounds.width - margin, bounds.width * Self.panSlackShare)
        camera.offset.y = axis(camera.offset.y, paperHeight * camera.scale, margin, bounds.height - margin, bounds.height * Self.panSlackShare)
        return camera
    }
}

enum InkStyle {
    static func tokens(for tool: Tool) -> Tokens.InkToolTokens {
        Preferences.inkTokens(tool)
    }

    static func color(for element: Element, style: PaperStyle) -> UIColor {
        let base = UIColor(hex: Palette.inkOnPaper(element.color ?? "#1A1A1A", style: style))
        guard let tool = element.tool else { return base }
        return base.withAlphaComponent(CGFloat(tokens(for: tool).opacity))
    }

    static var settings: InkSettings {
        let ink = Tokens.shared.ink
        return InkSettings(sampleSpacing: ink.sampleSpacingPoints, smoothing: ink.smoothingPoints, simplify: ink.simplifyPoints, axisSnapDegrees: ink.straightenAxisSnapDegrees)
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

    private static let minimumSpan: CGFloat = 1e-4

    private static func span(_ first: CGPoint, _ second: CGPoint) -> CGFloat {
        max(minimumSpan, sqrt(hypot(second.x - first.x, second.y - first.y)))
    }

    private static func controls(_ before: CGPoint, _ start: CGPoint, _ end: CGPoint, _ after: CGPoint) -> (CGPoint, CGPoint) {
        let leading = span(before, start)
        let middle = span(start, end)
        let trailing = span(end, after)
        let leadingWeight = 2 * leading * leading + 3 * leading * middle + middle * middle
        let trailingWeight = 2 * trailing * trailing + 3 * trailing * middle + middle * middle
        let leadingDivisor = 3 * leading * (leading + middle)
        let trailingDivisor = 3 * trailing * (trailing + middle)
        let first = CGPoint(
            x: (leading * leading * end.x - middle * middle * before.x + leadingWeight * start.x) / leadingDivisor,
            y: (leading * leading * end.y - middle * middle * before.y + leadingWeight * start.y) / leadingDivisor
        )
        let second = CGPoint(
            x: (trailing * trailing * start.x - middle * middle * after.x + trailingWeight * end.x) / trailingDivisor,
            y: (trailing * trailing * start.y - middle * middle * after.y + trailingWeight * end.y) / trailingDivisor
        )
        return (first, second)
    }

    static func makePath(_ points: [Point], transform: (Point) -> CGPoint = { CGPoint(x: $0.x, y: $0.y) }) -> CGPath {
        let path = CGMutablePath()
        let shown = points.map(transform)
        guard let first = shown.first else { return path }
        path.move(to: first)
        if shown.count == 1 {
            path.addLine(to: first)
            return path
        }
        if shown.count == 2 {
            path.addLine(to: shown[1])
            return path
        }
        let last = shown.count - 1
        for index in 0..<last {
            let start = shown[index]
            let end = shown[index + 1]
            let before = index > 0 ? shown[index - 1] : CGPoint(x: start.x * 2 - end.x, y: start.y * 2 - end.y)
            let after = index + 2 <= last ? shown[index + 2] : CGPoint(x: end.x * 2 - start.x, y: end.y * 2 - start.y)
            let (control1, control2) = controls(before, start, end, after)
            path.addCurve(to: end, control1: control1, control2: control2)
        }
        return path
    }
}

struct RenderOptions {
    var showsGuides = true
    var showsDividers = true
    var paperStyle: PaperStyle = .dark
    var hiddenElementIds: Set<String> = []
    var elementOffsets: [String: CGVector] = [:]
    var elementTransforms: [String: CGAffineTransform] = [:]
    var pixelScale: CGFloat = 2
    var fillsOutside = true
}

enum MarkdownText {
    struct LaidBlock {
        let block: MarkdownBlock
        let text: NSAttributedString
        let top: CGFloat
        let height: CGFloat
        let fontSize: CGFloat
        let indent: CGFloat
        let characterWidth: CGFloat
    }

    struct Layout {
        let blocks: [LaidBlock]
        let height: CGFloat
    }

    private static var cache: [String: Layout] = [:]
    private static let indentCharacters: CGFloat = 3

    static func font(_ size: CGFloat, isBold: Bool) -> UIFont {
        UIFont(name: isBold ? Typography.monoBoldName : Typography.monoName, size: size) ?? .monospacedSystemFont(ofSize: size, weight: isBold ? .bold : .regular)
    }

    static func lineHeight(_ size: CGFloat) -> CGFloat {
        font(size, isBold: false).lineHeight * CGFloat(Tokens.shared.text.lineHeight)
    }

    private static func attributed(_ block: MarkdownBlock, size: CGFloat, indent: CGFloat, color: UIColor) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = CGFloat(Tokens.shared.text.lineHeight)
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.firstLineHeadIndent = indent
        paragraph.headIndent = indent
        let result = NSMutableAttributedString()
        let ink = block.isChecked ? color.withAlphaComponent(0.55) : color
        let runs = block.runs.isEmpty ? [MarkdownRun(text: " ", style: MarkdownStyle())] : block.runs
        for run in runs {
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font(size, isBold: run.style.isBold),
                .foregroundColor: ink,
                .paragraphStyle: paragraph,
            ]
            if run.style.isItalic {
                attributes[.obliqueness] = 0.2
            }
            if run.style.isCode && block.kind != .code {
                attributes[.backgroundColor] = color.withAlphaComponent(0.14)
            }
            if run.style.isStruck {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if run.style.isLink {
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            result.append(NSAttributedString(string: run.text.isEmpty ? " " : run.text, attributes: attributes))
        }
        return result
    }

    static func layout(_ element: Element, color: UIColor) -> Layout {
        let fontSize = CGFloat(element.fontSize ?? Tokens.shared.text.fontSize)
        let width = CGFloat(element.box?.width ?? Tokens.shared.text.boxWidth)
        let content = element.content ?? ""
        let key = "\(fontSize)|\(width)|\(color.description)|\(content)"
        if let cached = cache[key] {
            return cached
        }
        var top: CGFloat = 0
        var blocks: [LaidBlock] = []
        for block in content.isEmpty ? [] : Markdown.blocks(content) {
            let size = fontSize * CGFloat(block.scale)
            let characterWidth = ("0" as NSString).size(withAttributes: [.font: font(size, isBold: false)]).width
            let indent = CGFloat(block.indent) * indentCharacters * characterWidth
            let text = attributed(block, size: size, indent: indent, color: color)
            let measured = block.kind == .rule ? lineHeight(size) : ceil(text.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).height)
            blocks.append(LaidBlock(block: block, text: text, top: top, height: measured, fontSize: size, indent: indent, characterWidth: characterWidth))
            top += measured
        }
        let layout = Layout(blocks: blocks, height: top)
        if cache.count > 500 {
            cache.removeAll()
        }
        cache[key] = layout
        return layout
    }

    static func draw(_ element: Element, at origin: CGPoint, color: UIColor, in context: CGContext) {
        guard let box = element.box else { return }
        let width = CGFloat(box.width)
        let layout = layout(element, color: color)
        UIGraphicsPushContext(context)
        for laid in layout.blocks {
            let rect = CGRect(x: origin.x, y: origin.y + laid.top, width: width, height: laid.height)
            switch laid.block.kind {
            case .code:
                context.setFillColor(color.withAlphaComponent(0.14).cgColor)
                context.fill(rect)
            case .rule:
                let thickness = max(0.15, laid.fontSize * 0.04)
                context.setFillColor(color.withAlphaComponent(0.45).cgColor)
                context.fill(CGRect(x: rect.minX, y: rect.midY - thickness / 2, width: width, height: thickness))
                continue
            case .quote:
                context.setFillColor(color.withAlphaComponent(0.5).cgColor)
                context.fill(CGRect(x: rect.minX + laid.characterWidth * 0.8, y: rect.minY, width: laid.fontSize * 0.12, height: rect.height))
            default:
                break
            }
            if let marker = laid.block.marker {
                let markerX = rect.minX + laid.indent - CGFloat(marker.count + 1) * laid.characterWidth
                let markerColor = laid.block.isChecked ? color.withAlphaComponent(0.55) : color
                (marker as NSString).draw(at: CGPoint(x: markerX, y: rect.minY), withAttributes: [.font: font(laid.fontSize, isBold: true), .foregroundColor: markerColor])
            }
            laid.text.draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        }
        UIGraphicsPopContext()
    }
}

enum PageRenderer {
    static func draw(_ page: Page, in context: CGContext, camera: CanvasCamera, visibleRect: CGRect, options: RenderOptions, cache: StrokePathCache) {
        if options.fillsOutside {
            context.setFillColor(Palette.outside.cgColor)
            context.fill(visibleRect)
        } else {
            context.clear(visibleRect)
        }

        let paperRect = CGRect(x: 0, y: 0, width: PaperGeometry.width(of: page.extent), height: PaperGeometry.height(of: page.extent))
        let visiblePage = camera.toPage(visibleRect).intersection(paperRect)
        guard !visiblePage.isNull else { return }
        let colors = Palette.paperColors(options.paperStyle)

        context.saveGState()
        context.translateBy(x: camera.offset.x, y: camera.offset.y)
        context.scaleBy(x: camera.scale, y: camera.scale)
        let radius = CGFloat(Tokens.shared.page.cornerRadius)
        context.addPath(CGPath(roundedRect: paperRect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.clip()
        context.setFillColor(UIColor(hex: colors.paper).cgColor)
        context.fill(paperRect)
        if options.showsGuides {
            drawGuides(in: context, visiblePage: visiblePage, camera: camera, color: UIColor(hex: colors.guide))
        }
        if options.showsDividers {
            drawCellBoundaries(in: context, extent: page.extent, camera: camera, color: UIColor(hex: colors.cellBoundary))
        }
        for element in page.liveElements where !options.hiddenElementIds.contains(element.id) {
            let offset = options.elementOffsets[element.id] ?? .zero
            let transform = options.elementTransforms[element.id]
            context.saveGState()
            context.translateBy(x: offset.dx, y: offset.dy)
            if let transform {
                context.concatenate(transform)
            }
            switch element.type {
            case .stroke:
                drawStroke(element, in: context, visiblePage: transform == nil ? visiblePage.offsetBy(dx: -offset.dx, dy: -offset.dy) : .infinite, cache: cache, style: options.paperStyle)
            case .text:
                drawText(element, in: context, style: options.paperStyle)
            case .importPage:
                drawImport(element, in: context, camera: camera, visiblePage: transform == nil ? visiblePage.offsetBy(dx: -offset.dx, dy: -offset.dy) : .infinite, options: options, guide: UIColor(hex: colors.guide))
            }
            context.restoreGState()
        }
        context.restoreGState()
    }

    static func textRect(for element: Element) -> CGRect? {
        guard element.type == .text, let box = element.box else { return nil }
        let height = MarkdownText.layout(element, color: .black).height
        return CGRect(x: box.x, y: box.y, width: box.width, height: max(height, CGFloat(element.fontSize ?? Tokens.shared.text.fontSize) * 1.4))
    }

    static func textAttributes(fontSize: CGFloat, color: UIColor) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = CGFloat(Tokens.shared.text.lineHeight)
        paragraph.lineBreakMode = .byWordWrapping
        return [.font: Typography.monoFont(fontSize), .foregroundColor: color, .paragraphStyle: paragraph]
    }

    private static func drawImport(_ element: Element, in context: CGContext, camera: CanvasCamera, visiblePage: CGRect, options: RenderOptions, guide: UIColor) {
        guard let size = element.sourceSizeMillimetres, size.count == 2, let placement = element.placement else { return }
        let rect = CGRect(x: placement.x, y: placement.y, width: size[0] * placement.scale, height: size[1] * placement.scale)
        guard rect.intersects(visiblePage) else { return }
        guard let image = ImportImages.shared.image(for: element, pixelsPerMillimetre: Double(camera.scale * options.pixelScale), isDark: options.paperStyle == .dark) else {
            context.setFillColor(guide.cgColor)
            context.fill(rect)
            return
        }
        context.saveGState()
        context.interpolationQuality = .medium
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }

    private static func drawStroke(_ element: Element, in context: CGContext, visiblePage: CGRect, cache: StrokePathCache, style: PaperStyle) {
        let cached = cache.path(for: element)
        guard cached.bounds.intersects(visiblePage) else { return }
        context.saveGState()
        context.addPath(cached.path)
        context.setLineWidth(CGFloat(element.width ?? 0.5))
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setStrokeColor(InkStyle.color(for: element, style: style).cgColor)
        context.strokePath()
        context.restoreGState()
    }

    private static func drawText(_ element: Element, in context: CGContext, style: PaperStyle) {
        guard let box = element.box, let content = element.content, !content.isEmpty else { return }
        let color = UIColor(hex: Palette.inkOnPaper(element.color ?? Tokens.shared.text.color, style: style))
        MarkdownText.draw(element, at: CGPoint(x: CGFloat(box.x), y: CGFloat(box.y)), color: color, in: context)
    }

    private static func drawGuides(in context: CGContext, visiblePage: CGRect, camera: CanvasCamera, color: UIColor) {
        let spacing = CGFloat(PaperGeometry.gridSpacing)
        guard spacing * camera.scale >= 4 else { return }
        context.saveGState()
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(1 / camera.scale)
        var x = (visiblePage.minX / spacing).rounded(.down) * spacing
        while x <= visiblePage.maxX {
            context.move(to: CGPoint(x: x, y: visiblePage.minY))
            context.addLine(to: CGPoint(x: x, y: visiblePage.maxY))
            x += spacing
        }
        let cellHeight = CGFloat(PaperGeometry.cellHeight)
        let rowSpacing = cellHeight / max(1, (cellHeight / spacing).rounded())
        var row = (visiblePage.minY / rowSpacing).rounded(.down)
        while row * rowSpacing <= visiblePage.maxY {
            context.move(to: CGPoint(x: visiblePage.minX, y: row * rowSpacing))
            context.addLine(to: CGPoint(x: visiblePage.maxX, y: row * rowSpacing))
            row += 1
        }
        context.strokePath()
        context.restoreGState()
    }

    private static func drawCellBoundaries(in context: CGContext, extent: Extent, camera: CanvasCamera, color: UIColor) {
        guard extent.cellCount > 1 else { return }
        let width = CGFloat(PaperGeometry.cellWidth)
        let height = CGFloat(PaperGeometry.cellHeight)
        context.saveGState()
        context.setStrokeColor(color.cgColor)
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

    static func thumbnail(of page: Page, size: CGSize, options: RenderOptions) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        let cache = StrokePathCache()
        return renderer.image { rendererContext in
            let width = PaperGeometry.width(of: page.extent)
            let height = PaperGeometry.height(of: page.extent)
            let scale = min(size.width / width, size.height / height)
            let offset = CGPoint(x: (size.width - width * scale) / 2, y: (size.height - height * scale) / 2)
            let camera = CanvasCamera(scale: scale, offset: offset)
            draw(page, in: rendererContext.cgContext, camera: camera, visibleRect: CGRect(origin: .zero, size: size), options: options, cache: cache)
        }
    }
}
