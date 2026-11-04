import NotesCore
import UIKit

struct TileSnapshot {
    let page: Page
    let index: RenderIndex
    let options: RenderOptions
    let cache: StrokePathCache
}

enum TilePass: Int, CaseIterable {
    case lines
    case markers
    case elements
}

final class CanvasTiles {
    struct Key: Hashable {
        let level: Int
        let column: Int
        let row: Int
    }

    private final class Tile {
        let key: Key
        let rect: CGRect
        var layers: [CALayer?] = Array(repeating: nil, count: TilePass.allCases.count)
        var images: [CGImage?] = Array(repeating: nil, count: TilePass.allCases.count)
        var hasContent = false
        var isStale = true
        var ticket = 0
        var operation: Operation?
        var bytes = 0

        init(key: Key, rect: CGRect) {
            self.key = key
            self.rect = rect
        }
    }

    let containers: [CALayer] = TilePass.allCases.map { _ in CanvasTiles.makeQuietLayer() }
    var pixelScale: CGFloat = 2
    var baseLevel = 0

    private var tiles: [Key: Tile] = [:]
    private var snapshot: TileSnapshot?
    private var camera = CanvasCamera()
    private var viewSize: CGSize = .zero
    private var paper: CGRect = .null
    private var bytes = 0
    private var isCoverageQueued = false
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.vaditim.notes.tiles"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = max(2, ProcessInfo.processInfo.activeProcessorCount - 2)
        return queue
    }()

    private static let tilePoints: CGFloat = 256
    private static let levelBias: CGFloat = 0.25
    private static let levels = -10...8
    private static let tileLimit = 1500
    private static let quietActions: [String: CAAction] = ["contents": NSNull(), "position": NSNull(), "bounds": NSNull(), "transform": NSNull(), "hidden": NSNull(), "opacity": NSNull(), "sublayers": NSNull()]

    private var budget: Int {
        Tokens.shared.memory.tileCacheMegabytes * 1024 * 1024
    }

    static func makeQuietLayer() -> CALayer {
        let layer = CALayer()
        layer.anchorPoint = .zero
        layer.actions = quietActions
        return layer
    }

    static func level(for scale: CGFloat) -> Int {
        let level = Int((log2(max(scale, 1e-6)) - levelBias).rounded(.up))
        return min(levels.upperBound, max(levels.lowerBound, level))
    }

    private static func levelScale(_ level: Int) -> CGFloat {
        pow(2, CGFloat(level))
    }

    private static func tileSize(_ level: Int) -> CGFloat {
        tilePoints / levelScale(level)
    }

    private static func rect(for key: Key) -> CGRect {
        let size = tileSize(key.level)
        return CGRect(x: CGFloat(key.column) * size, y: CGFloat(key.row) * size, width: size, height: size)
    }

    private static func keys(level: Int, covering area: CGRect) -> [Key] {
        guard !area.isNull, !area.isEmpty else { return [] }
        let size = tileSize(level)
        let firstColumn = Int((area.minX / size).rounded(.down))
        let lastColumn = Int((area.maxX / size).rounded(.up)) - 1
        let firstRow = Int((area.minY / size).rounded(.down))
        let lastRow = Int((area.maxY / size).rounded(.up)) - 1
        guard lastColumn >= firstColumn, lastRow >= firstRow else { return [] }
        var keys: [Key] = []
        keys.reserveCapacity((lastColumn - firstColumn + 1) * (lastRow - firstRow + 1))
        for row in firstRow...lastRow {
            for column in firstColumn...lastColumn {
                keys.append(Key(level: level, column: column, row: row))
            }
        }
        return keys
    }

    func reset(_ snapshot: TileSnapshot?) {
        queue.cancelAllOperations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for tile in tiles.values {
            tile.layers.forEach { $0?.removeFromSuperlayer() }
        }
        CATransaction.commit()
        tiles = [:]
        bytes = 0
        self.snapshot = snapshot
    }

    func invalidateAll(_ snapshot: TileSnapshot?) {
        self.snapshot = snapshot
        for tile in tiles.values {
            markStale(tile)
        }
    }

    func invalidate(_ area: CGRect, snapshot: TileSnapshot?) {
        self.snapshot = snapshot
        guard !area.isNull, !area.isEmpty, let snapshot else { return }
        let level = Self.level(for: camera.scale)
        let visible = visiblePage()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for tile in Array(tiles.values) where tile.rect.intersects(area) {
            if tile.key.level == level || tile.key.level == baseLevel {
                if tile.key.level == level, tile.hasContent, !tile.isStale, tile.rect.intersects(visible) {
                    patch(tile, area: area, snapshot: snapshot)
                } else {
                    markStale(tile)
                }
            } else {
                remove(tile)
            }
        }
        CATransaction.commit()
    }

    func update(camera: CanvasCamera, size: CGSize, paper: CGRect, synchronous: Bool = false) {
        self.camera = camera
        self.viewSize = size
        self.paper = paper
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let transform = CGAffineTransform(a: camera.scale, b: 0, c: 0, d: camera.scale, tx: camera.offset.x, ty: camera.offset.y)
        for container in containers {
            container.position = .zero
            container.setAffineTransform(transform)
        }
        defer { CATransaction.commit() }
        guard snapshot != nil, size.width > 0, size.height > 0, !paper.isNull else { return }
        let level = Self.level(for: camera.scale)
        let visible = visiblePage()
        let margin = Self.tileSize(level)
        let prefetch = visible.isNull ? CGRect.null : visible.insetBy(dx: -margin, dy: -margin).intersection(paper)
        let centre = CGPoint(x: visible.midX, y: visible.midY)
        let visibleKeys = Self.keys(level: level, covering: visible).sorted { first, second in
            Self.distance(Self.rect(for: first), to: centre) < Self.distance(Self.rect(for: second), to: centre)
        }
        let visibleSet = Set(visibleKeys)
        let prefetchKeys = Self.keys(level: level, covering: prefetch).filter { !visibleSet.contains($0) }
        let baseKeys = level == baseLevel ? [] : Self.keys(level: baseLevel, covering: paper)
        var needed = visibleSet
        needed.formUnion(prefetchKeys)
        needed.formUnion(baseKeys)
        for key in baseKeys {
            ensure(key, priority: .veryHigh, synchronous: false)
        }
        for key in visibleKeys {
            ensure(key, priority: .high, synchronous: synchronous)
        }
        for key in prefetchKeys {
            ensure(key, priority: .normal, synchronous: false)
        }
        for (key, tile) in tiles where !needed.contains(key) {
            if let operation = tile.operation {
                operation.cancel()
                tile.operation = nil
            }
        }
        refreshCoverage()
        trim(keeping: needed)
    }

    func cancelPending() {
        queue.cancelAllOperations()
        for tile in tiles.values {
            tile.operation = nil
        }
    }

    func releaseMemory() {
        let level = Self.level(for: camera.scale)
        let visible = visiblePage()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for tile in Array(tiles.values) where !(tile.key.level == level && tile.rect.intersects(visible)) && tile.key.level != baseLevel {
            remove(tile)
        }
        CATransaction.commit()
    }

    private func visiblePage() -> CGRect {
        guard viewSize.width > 0, viewSize.height > 0, !paper.isNull else { return .null }
        return camera.toPage(CGRect(origin: .zero, size: viewSize)).intersection(paper)
    }

    private static func distance(_ rect: CGRect, to point: CGPoint) -> CGFloat {
        hypot(rect.midX - point.x, rect.midY - point.y)
    }

    private func markStale(_ tile: Tile) {
        tile.isStale = true
        tile.ticket += 1
        tile.operation?.cancel()
        tile.operation = nil
    }

    private func remove(_ tile: Tile) {
        tile.operation?.cancel()
        tile.layers.forEach { $0?.removeFromSuperlayer() }
        bytes -= tile.bytes
        tiles[tile.key] = nil
    }

    private func ensure(_ key: Key, priority: Operation.QueuePriority, synchronous: Bool) {
        let tile: Tile
        if let existing = tiles[key] {
            tile = existing
        } else {
            tile = Tile(key: key, rect: Self.rect(for: key))
            tiles[key] = tile
        }
        guard tile.isStale, let snapshot else { return }
        if synchronous {
            tile.operation?.cancel()
            tile.operation = nil
            tile.ticket += 1
            let images = TilePass.allCases.map { Self.render($0, rect: tile.rect, level: key.level, snapshot: snapshot, pixelScale: pixelScale, base: nil, area: nil) }
            apply(images, to: tile)
            return
        }
        if let operation = tile.operation {
            operation.queuePriority = priority
            return
        }
        let ticket = tile.ticket
        let rect = tile.rect
        let scale = pixelScale
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak self, weak operation] in
            guard let operation, !operation.isCancelled else { return }
            let images = TilePass.allCases.map { Self.render($0, rect: rect, level: key.level, snapshot: snapshot, pixelScale: scale, base: nil, area: nil) }
            guard !operation.isCancelled else { return }
            DispatchQueue.main.async {
                guard let self, let tile = self.tiles[key], tile.ticket == ticket else { return }
                tile.operation = nil
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.apply(images, to: tile)
                CATransaction.commit()
                self.queueCoverage()
            }
        }
        operation.queuePriority = priority
        tile.operation = operation
        queue.addOperation(operation)
    }

    private func patch(_ tile: Tile, area: CGRect, snapshot: TileSnapshot) {
        var images = tile.images
        for pass in [TilePass.markers, TilePass.elements] {
            images[pass.rawValue] = Self.render(pass, rect: tile.rect, level: tile.key.level, snapshot: snapshot, pixelScale: pixelScale, base: tile.images[pass.rawValue], area: area)
        }
        tile.ticket += 1
        apply(images, to: tile)
    }

    private func apply(_ images: [CGImage?], to tile: Tile) {
        var tileBytes = 0
        for pass in TilePass.allCases {
            let image = images[pass.rawValue]
            tile.images[pass.rawValue] = image
            if let image {
                tileBytes += image.bytesPerRow * image.height
                let layer = tile.layers[pass.rawValue] ?? makeLayer(for: tile, pass: pass)
                layer.contents = image
            } else if let layer = tile.layers[pass.rawValue] {
                layer.removeFromSuperlayer()
                tile.layers[pass.rawValue] = nil
            }
        }
        bytes += tileBytes - tile.bytes
        tile.bytes = tileBytes
        tile.hasContent = true
        tile.isStale = false
    }

    private func makeLayer(for tile: Tile, pass: TilePass) -> CALayer {
        let layer = Self.makeQuietLayer()
        layer.bounds = CGRect(origin: .zero, size: tile.rect.size)
        layer.position = tile.rect.origin
        layer.contentsGravity = .resize
        layer.magnificationFilter = .linear
        layer.minificationFilter = .linear
        layer.zPosition = CGFloat(tile.key.level)
        layer.isOpaque = false
        containers[pass.rawValue].addSublayer(layer)
        tile.layers[pass.rawValue] = layer
        return layer
    }

    private func queueCoverage() {
        guard !isCoverageQueued else { return }
        isCoverageQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isCoverageQueued = false
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.refreshCoverage()
            CATransaction.commit()
        }
    }

    private func refreshCoverage() {
        let level = Self.level(for: camera.scale)
        let visible = visiblePage()
        for tile in tiles.values where tile.layers.contains(where: { $0 != nil }) {
            let isHidden: Bool
            if tile.key.level == level {
                isHidden = false
            } else {
                let shown = tile.rect.intersection(visible)
                isHidden = shown.isNull || shown.isEmpty || Self.keys(level: level, covering: shown.insetBy(dx: 1e-3, dy: 1e-3)).allSatisfy { tiles[$0]?.hasContent ?? false }
            }
            for layer in tile.layers where layer?.isHidden != isHidden {
                layer?.isHidden = isHidden
            }
        }
    }

    private func trim(keeping needed: Set<Key>) {
        guard bytes > budget || tiles.count > Self.tileLimit else { return }
        let level = Self.level(for: camera.scale)
        let visible = visiblePage()
        let centre = CGPoint(x: visible.midX, y: visible.midY)
        let candidates = tiles.values.filter { !needed.contains($0.key) }.sorted { first, second in
            let firstGap = abs(first.key.level - level)
            let secondGap = abs(second.key.level - level)
            if firstGap != secondGap {
                return firstGap > secondGap
            }
            return Self.distance(first.rect, to: centre) > Self.distance(second.rect, to: centre)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for tile in candidates {
            guard bytes > budget || tiles.count > Self.tileLimit else { break }
            remove(tile)
        }
        CATransaction.commit()
    }

    private static func hasLines(in rect: CGRect, level: Int, snapshot: TileSnapshot) -> Bool {
        let options = snapshot.options
        if options.showsGuides, CGFloat(PaperGeometry.gridSpacing) * levelScale(level) >= 4 {
            return true
        }
        guard options.showsDividers, snapshot.page.extent.cellCount > 1 else { return false }
        let width = CGFloat(PaperGeometry.cellWidth)
        let height = CGFloat(PaperGeometry.cellHeight)
        let crossesColumn = (1..<max(2, snapshot.page.extent.columns)).contains { column in
            column < snapshot.page.extent.columns && CGFloat(column) * width >= rect.minX - 1 && CGFloat(column) * width <= rect.maxX + 1
        }
        let crossesRow = (1..<max(2, snapshot.page.extent.rows)).contains { row in
            row < snapshot.page.extent.rows && CGFloat(row) * height >= rect.minY - 1 && CGFloat(row) * height <= rect.maxY + 1
        }
        return crossesColumn || crossesRow
    }

    private static func hasItems(_ items: [RenderIndex.Item], in rect: CGRect, hidden: Set<String>) -> Bool {
        items.contains { $0.bounds.intersects(rect) && !hidden.contains($0.element.id) }
    }

    static func render(_ pass: TilePass, rect: CGRect, level: Int, snapshot: TileSnapshot, pixelScale: CGFloat, base: CGImage?, area: CGRect?) -> CGImage? {
        var options = snapshot.options
        options.fillsOutside = false
        options.drawsPaper = false
        options.drawsImports = false
        switch pass {
        case .lines:
            guard hasLines(in: rect, level: level, snapshot: snapshot) else { return nil }
            options.drawsElements = false
            options.drawsLines = true
        case .markers:
            guard hasItems(snapshot.index.markers, in: rect, hidden: options.hiddenElementIds) else { return nil }
            options.drawsLines = false
            options.markerPass = .only
        case .elements:
            guard hasItems(snapshot.index.others, in: rect, hidden: options.hiddenElementIds) else { return nil }
            options.drawsLines = false
            options.markerPass = .none
        }
        options.pixelScale = pixelScale
        let scale = levelScale(level)
        let size = CGSize(width: tilePoints, height: tilePoints)
        let format = UIGraphicsImageRendererFormat()
        format.scale = pixelScale
        format.opaque = false
        format.preferredRange = .standard
        let tileCamera = CanvasCamera(scale: scale, offset: CGPoint(x: -rect.minX * scale, y: -rect.minY * scale))
        let image = UIGraphicsImageRenderer(size: size, format: format).image { rendererContext in
            let context = rendererContext.cgContext
            var shown = CGRect(origin: .zero, size: size)
            if let base, let area {
                UIImage(cgImage: base, scale: pixelScale, orientation: .up).draw(in: shown)
                let screen = CGRect(x: (area.minX - rect.minX) * scale, y: (area.minY - rect.minY) * scale, width: area.width * scale, height: area.height * scale)
                shown = screen.insetBy(dx: -2, dy: -2).integral.intersection(shown)
                guard !shown.isNull, !shown.isEmpty else { return }
                context.clip(to: shown)
            }
            PageRenderer.draw(snapshot.page, in: context, camera: tileCamera, visibleRect: shown, options: options, cache: snapshot.cache, index: snapshot.index)
        }
        return image.cgImage
    }
}
