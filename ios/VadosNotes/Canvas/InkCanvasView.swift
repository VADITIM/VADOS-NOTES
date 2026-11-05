import NotesCore
import QuartzCore
import UIKit
import UIKit.UIGestureRecognizerSubclass

enum CanvasTool: Equatable {
    case ink(Tool)
    case eraser(EraserMode)
    case text
    case lasso
}

private final class StrokeSession {
    var raw: [Point]
    var screenLength: CGFloat = 0
    var lastLocation: CGPoint
    var stillLocation: CGPoint
    var stillTimer: Timer?
    var straightEnd: Point?
    var straightShare: Double = 0
    var predicted: [Point] = []

    init(location: CGPoint, point: Point) {
        raw = [point]
        lastLocation = location
        stillLocation = location
    }
}

private struct AreaEntry {
    let element: Element
    var pieces: [[Point]]
    var revision: Int
}

private struct PressedText {
    let id: String
    let origin: TextBox
    let start: Point
    let height: Double
}

final class CleanTapGestureRecognizer: UITapGestureRecognizer {
    var maximumTravel: CGFloat = 10
    var maximumDuration: TimeInterval = 0.25

    private var starts: [ObjectIdentifier: CGPoint] = [:]
    private var beganAt: TimeInterval?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        for touch in touches {
            starts[ObjectIdentifier(touch)] = touch.location(in: view)
            beganAt = beganAt ?? touch.timestamp
        }
        super.touchesBegan(touches, with: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        for touch in touches {
            guard let start = starts[ObjectIdentifier(touch)] else { continue }
            let location = touch.location(in: view)
            if hypot(location.x - start.x, location.y - start.y) > maximumTravel {
                state = .failed
                return
            }
        }
        super.touchesMoved(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        if let beganAt, let touch = touches.first, touch.timestamp - beganAt > maximumDuration {
            state = .failed
            return
        }
        super.touchesEnded(touches, with: event)
    }

    override func reset() {
        super.reset()
        starts = [:]
        beganAt = nil
    }
}

private final class ElementCanvasView: UIView {
    var render: ((CGContext, CGRect) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        contentMode = .redraw
        layer.anchorPoint = .zero
    }

    required init?(coder: NSCoder) {
        fatalError("ElementCanvasView is created in code")
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        render?(context, rect)
    }
}

final class InkCanvasView: UIView, UIGestureRecognizerDelegate, UIPencilInteractionDelegate {
    var page: Page? {
        didSet {
            guard page != oldValue else { return }
            if oldValue?.id != page?.id {
                hasFitted = false
                selectedIds = []
                setNeedsLayout()
            }
            let previous = renderIndex
            renderIndex = nil
            let erasedBounds = previous?.bounds(of: Set(pendingErased).union(areaErase.keys)) ?? .null
            clearPendingFeedback()
            refreshSelection()
            layoutPaper()
            if let previous, oldValue?.id == page?.id, oldValue?.extent == page?.extent {
                refreshContent(adding: currentIndex().changedBounds(since: previous).union(erasedBounds))
                return
            }
            rebuildTiles(clearing: oldValue?.id != page?.id)
        }
    }
    var tool: CanvasTool = .ink(.pen)
    var inkColor = "#1A1A1A"
    var inkWidth = 0.5
    var eraserRadius = 2.0
    var isReadOnly = false
    var paperStyle: PaperStyle = .dark {
        didSet {
            guard paperStyle != oldValue else { return }
            layoutPaper()
            rebuildTiles(clearing: false)
        }
    }
    var writingFont = "" {
        didSet {
            guard writingFont != oldValue else { return }
            renderIndex = nil
            rebuildTiles(clearing: false)
        }
    }
    var showsGuides = true {
        didSet { if showsGuides != oldValue { rebuildTiles(clearing: false) } }
    }
    var showsDividers = true {
        didSet { if showsDividers != oldValue { rebuildTiles(clearing: false) } }
    }
    var showsBackdrop = false {
        didSet {
            guard showsBackdrop != oldValue else { return }
            backgroundColor = showsBackdrop ? .clear : Palette.outside
            isOpaque = !showsBackdrop
        }
    }
    var inkSmoothing = Tokens.shared.ink.smoothingPoints
    var hiddenElementIds: Set<String> = [] {
        didSet {
            guard hiddenElementIds != oldValue else { return }
            refreshContent()
        }
    }
    var topInset: CGFloat = 0 {
        didSet {
            guard topInset != oldValue else { return }
            if !hasFitted || isCameraFitted(inset: oldValue) {
                hasFitted = false
                setNeedsLayout()
            }
        }
    }

    var onCameraChange: ((CanvasCamera) -> Void)?
    var onStroke: ((Tool, String, [[Point]], Double) -> Void)?
    var onErase: (([String]) -> Void)?
    var onEraseArea: (([StrokeReplacement]) -> Void)?
    var onTextTap: ((Point, String?) -> Void)?
    var onTextMove: ((String, TextBox) -> Void)?
    var onMoveElements: (([String], Point) -> Void)?
    var onScaleElements: (([String], Point, Double) -> Void)?
    var onSelectionMenu: ((SelectionMenuRequest?) -> Void)?
    var onInput: (() -> Void)?
    var selectionCommand: SelectionCommand? {
        didSet {
            guard let selectionCommand, selectionCommand != oldValue, !isReadOnly else { return }
            selectedIds = selectionCommand.ids
            refreshSelection()
            refreshContent()
        }
    }
    var onHold: ((CGPoint, Point) -> Void)?
    var onHoldMove: ((CGPoint) -> Void)?
    var onHoldEnd: ((CGPoint) -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var onPencilTap: (() -> Void)?
    var onEraseLift: (() -> Void)?

    private(set) var camera = CanvasCamera()
    private let cache = StrokePathCache()
    private let tiles = CanvasTiles()
    private let paperLayer = CAShapeLayer()
    private let markerGroup = CanvasTiles.makeQuietLayer()
    private var shownTileHiddenIds: Set<String> = []
    private var shownAreaRevisions: [String: Int] = [:]
    private let liveLayer = CAShapeLayer()
    private let liveMask = CAShapeLayer()
    private let eraserLayer = CAShapeLayer()
    private let lassoLayer = CAShapeLayer()
    private let selectionLayer = CAShapeLayer()
    private let movingCanvas = ElementCanvasView(frame: .zero)
    private let liveMarkerLayer = CAShapeLayer()
    private let liveMarkerMask = CAShapeLayer()
    private let importContainer = CALayer()
    private let importMask = CAShapeLayer()
    private var importLayers: [String: CALayer] = [:]
    private var activeTouch: UITouch?
    private var isFingerTouch = false
    private var stroke: StrokeSession?
    private var snapLink: CADisplayLink?
    private var glideLink: CADisplayLink?
    private var glideVelocity: CGPoint = .zero
    private var glideLast: CFTimeInterval = 0
    private var panSamples: [(location: CGPoint, time: TimeInterval)] = []
    private var snapStart: CFTimeInterval = 0
    private var lastErasePoint: Point?
    private var gestureStart: CGPoint = .zero
    private var lastPanLocation: CGPoint = .zero
    private var hasMoved = false
    private var holdTimer: Timer?
    private var isHolding = false
    private var isPanning = false
    private var pendingErased: [String] = []
    private var areaErase: [String: AreaEntry] = [:]
    private var pressedText: PressedText?
    private var textHoldTimer: Timer?
    private var isTextLifted = false
    private var textOffset: CGVector = .zero
    private var lassoPoints: [Point] = []
    private var selectedIds: [String] = []
    private var selectionBounds: CGRect?
    private var selectionStart: Point?
    private var selectionOffset: CGVector = .zero
    private var isSelectionTouchInside = false
    private var selectionScaleAnchor: CGPoint?
    private var selectionScale: CGFloat = 1
    private var hasFitted = false
    private var fittedSize: CGSize = .zero
    private var importObserver: NSObjectProtocol?
    private var memoryObserver: NSObjectProtocol?
    private let palmGuard = PalmGuard()
    private var renderIndex: RenderIndex?
    private var cameraSettleTimer: Timer?
    private var touchCamera: CanvasCamera?

    private static let fitMargin: CGFloat = 24
    private static let holdTolerance: CGFloat = 8
    private static let minimumEraserReach: CGFloat = 6
    private static let minimumSampleSpacing: CGFloat = 0.25
    private static let minimumStraightLength: CGFloat = 24
    private static let selectionPadding: CGFloat = 8
    private static let lassoDash: [NSNumber] = [6, 5]
    private static let selectionScaleRange: ClosedRange<CGFloat> = 0.1...10
    private static let glideStopSpeed: CGFloat = 12
    private static let glideSampleWindow: TimeInterval = 0.08
    private static let undoTapTravel: CGFloat = 10
    private static let cameraSettleSeconds: TimeInterval = 0.12

    private func currentIndex() -> RenderIndex {
        if let renderIndex {
            return renderIndex
        }
        guard let page else { return RenderIndex(imports: [], markers: [], others: []) }
        let index = RenderIndex(page, cache: cache)
        cache.prune(keeping: index.markers.count + index.others.count) { index.byId[$0] != nil }
        renderIndex = index
        return index
    }

    private var paperRect: CGRect {
        guard let page else { return .null }
        return CGRect(x: 0, y: 0, width: PaperGeometry.width(of: page.extent), height: PaperGeometry.height(of: page.extent))
    }

    private func movingIds() -> Set<String> {
        var ids = Set<String>()
        if selectionOffset != .zero || selectionScaleAnchor != nil {
            ids.formUnion(selectedIds)
        }
        if let pressedText, isTextLifted {
            ids.insert(pressedText.id)
        }
        return ids
    }

    private func tileHiddenIds() -> Set<String> {
        hiddenElementIds.union(pendingErased).union(movingIds())
    }

    private func tileSnapshot() -> TileSnapshot? {
        guard var page else { return nil }
        var index = currentIndex()
        if !areaErase.isEmpty {
            var pieces: [RenderIndex.Item] = []
            for (elementId, entry) in areaErase {
                for (position, points) in entry.pieces.enumerated() {
                    var piece = entry.element
                    piece.id = "\(elementId)-piece-\(position)-\(entry.revision)"
                    piece.points = points
                    pieces.append(RenderIndex.Item(element: piece, bounds: cache.path(for: piece).bounds))
                }
            }
            let erasing = areaErase
            let isKept = { (item: RenderIndex.Item) in erasing[item.element.id] == nil }
            let pieceMarkers = pieces.filter { InkStyle.isMarker($0.element) }
            let pieceOthers = pieces.filter { !InkStyle.isMarker($0.element) }
            index = RenderIndex(imports: index.imports, markers: index.markers.filter(isKept) + pieceMarkers, others: index.others.filter(isKept) + pieceOthers)
            page.elements = []
        }
        var options = renderOptions()
        options.hiddenElementIds = tileHiddenIds()
        return TileSnapshot(page: page, index: index, options: options, cache: cache)
    }

    private func refreshContent(adding extra: CGRect = .null) {
        let index = currentIndex()
        let hidden = tileHiddenIds()
        var dirty = extra.union(index.bounds(of: hidden.symmetricDifference(shownTileHiddenIds)))
        let revisions = areaErase.mapValues(\.revision)
        for (id, revision) in revisions where shownAreaRevisions[id] != revision {
            dirty = dirty.union(index.bounds(of: [id]))
        }
        for id in shownAreaRevisions.keys where revisions[id] == nil {
            dirty = dirty.union(index.bounds(of: [id]))
        }
        shownTileHiddenIds = hidden
        shownAreaRevisions = revisions
        layoutImports()
        if !dirty.isNull {
            tiles.invalidate(dirty, snapshot: tileSnapshot())
            updateTiles()
        }
        refreshMoving()
    }

    private func rebuildTiles(clearing: Bool) {
        shownTileHiddenIds = tileHiddenIds()
        shownAreaRevisions = areaErase.mapValues(\.revision)
        if clearing {
            tiles.reset(tileSnapshot())
        } else {
            tiles.invalidateAll(tileSnapshot())
        }
        updateTiles(synchronous: hasFitted)
        layoutImports()
        refreshMoving()
    }

    private func updateTiles(synchronous: Bool = false) {
        guard let page, bounds.width > 0, bounds.height > 0 else { return }
        tiles.pixelScale = pixelScale
        tiles.baseLevel = CanvasTiles.level(for: CanvasCamera.smallestScale(for: page.extent, in: bounds.size, margin: Self.fitMargin, topInset: topInset))
        tiles.update(camera: camera, size: bounds.size, paper: paperRect, synchronous: synchronous)
    }

    private func refreshMoving() {
        let isMoving = !movingIds().isEmpty
        movingCanvas.isHidden = !isMoving
        if isMoving {
            movingCanvas.setNeedsDisplay()
        }
    }

    private func layoutPaper() {
        guard page != nil else {
            paperLayer.path = nil
            return
        }
        let paper = paperRect
        let radius = CGFloat(Tokens.shared.page.cornerRadius) * camera.scale
        let screen = CGRect(x: camera.offset.x + paper.minX * camera.scale, y: camera.offset.y + paper.minY * camera.scale, width: paper.width * camera.scale, height: paper.height * camera.scale)
        let paperPath = CGPath(roundedRect: screen, cornerWidth: radius, cornerHeight: radius, transform: nil)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        paperLayer.fillColor = UIColor(hex: Palette.paperColors(paperStyle).paper).cgColor
        paperLayer.path = paperPath
        liveMask.path = paperPath
        liveMarkerMask.path = paperPath
        importMask.path = paperPath
        CATransaction.commit()
    }

    private var pixelScale: CGFloat {
        window?.screen.scale ?? 2
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = Palette.outside
        paperLayer.actions = ["path": NSNull(), "fillColor": NSNull()]
        layer.addSublayer(paperLayer)
        importContainer.mask = importMask
        layer.addSublayer(importContainer)
        layer.addSublayer(tiles.containers[TilePass.lines.rawValue])
        markerGroup.opacity = Float(InkStyle.tokens(for: .marker).opacity)
        markerGroup.addSublayer(tiles.containers[TilePass.markers.rawValue])
        layer.addSublayer(markerGroup)
        layer.addSublayer(tiles.containers[TilePass.elements.rawValue])
        movingCanvas.isHidden = true
        addSubview(movingCanvas)
        liveLayer.fillColor = nil
        liveLayer.lineCap = .round
        liveLayer.lineJoin = .round
        liveLayer.mask = liveMask
        layer.addSublayer(liveLayer)
        eraserLayer.fillColor = UIColor(Palette.destructive).withAlphaComponent(0.12).cgColor
        eraserLayer.strokeColor = UIColor(Palette.destructive).withAlphaComponent(0.9).cgColor
        eraserLayer.lineWidth = 1.5
        layer.addSublayer(eraserLayer)
        lassoLayer.fillColor = UIColor(Palette.accent).withAlphaComponent(0.08).cgColor
        lassoLayer.strokeColor = UIColor(Palette.accent).cgColor
        lassoLayer.lineWidth = 1.5
        lassoLayer.lineDashPattern = Self.lassoDash
        layer.addSublayer(lassoLayer)
        selectionLayer.fillColor = UIColor(Palette.accent).withAlphaComponent(0.06).cgColor
        selectionLayer.strokeColor = UIColor(Palette.accent).cgColor
        selectionLayer.lineWidth = 1.5
        selectionLayer.lineDashPattern = Self.lassoDash
        layer.addSublayer(selectionLayer)
        liveMarkerLayer.fillColor = nil
        liveMarkerLayer.lineCap = .round
        liveMarkerLayer.lineJoin = .round
        liveMarkerLayer.anchorPoint = .zero
        liveMarkerLayer.mask = liveMarkerMask
        markerGroup.addSublayer(liveMarkerLayer)
        movingCanvas.render = { [weak self] context, rect in
            self?.drawMoving(in: context, rect: rect)
        }

        let pencil = UIPencilInteraction()
        pencil.delegate = self
        addInteraction(pencil)

        palmGuard.view = self
        let palmWatch = PalmWatchGestureRecognizer(palmGuard: palmGuard)
        palmWatch.delegate = self
        addGestureRecognizer(palmWatch)

        let pinch = GuardedPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.palmGuard = palmGuard
        pinch.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        pinch.delegate = self
        addGestureRecognizer(pinch)

        let pan = GuardedPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.palmGuard = palmGuard
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        pan.delegate = self
        addGestureRecognizer(pan)

        let undoTap = CleanTapGestureRecognizer(target: self, action: #selector(handleUndoTap))
        undoTap.maximumTravel = Self.undoTapTravel
        undoTap.maximumDuration = Motion.seconds(Motion.undoTapMilliseconds)
        undoTap.numberOfTouchesRequired = 2
        undoTap.numberOfTapsRequired = 1
        undoTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        undoTap.delegate = self
        addGestureRecognizer(undoTap)

        let redoTap = CleanTapGestureRecognizer(target: self, action: #selector(handleRedoTap))
        redoTap.maximumTravel = Self.undoTapTravel
        redoTap.maximumDuration = Motion.seconds(Motion.undoTapMilliseconds)
        redoTap.numberOfTouchesRequired = 3
        redoTap.numberOfTapsRequired = 1
        redoTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        redoTap.delegate = self
        addGestureRecognizer(redoTap)
        undoTap.require(toFail: redoTap)
        for tap in [undoTap, redoTap] {
            tap.require(toFail: pinch)
            tap.require(toFail: pan)
        }

        importObserver = NotificationCenter.default.addObserver(forName: ImportImages.didRender, object: nil, queue: .main) { [weak self] _ in
            self?.layoutImports()
        }
        memoryObserver = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            self?.releaseMemory()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("InkCanvasView is created in code")
    }

    deinit {
        for observer in [importObserver, memoryObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
        }
        ImportImages.shared.hold([], for: ObjectIdentifier(self))
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        guard newWindow == nil else { return }
        stopGlide()
        snapLink?.invalidate()
        snapLink = nil
        cameraSettleTimer?.invalidate()
        cameraSettleTimer = nil
        holdTimer?.invalidate()
        holdTimer = nil
        textHoldTimer?.invalidate()
        textHoldTimer = nil
        stroke?.stillTimer?.invalidate()
        tiles.cancelPending()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            updateTiles()
        }
    }

    private func releaseMemory() {
        cache.removeAll()
        renderIndex = nil
        MarkdownText.removeCachedLayouts()
        for sublayer in importLayers.values where sublayer.isHidden {
            sublayer.contents = nil
        }
        tiles.releaseMemory()
    }

    func fit() {
        guard let page, bounds.width > 0 else { return }
        camera = CanvasCamera.fitting(page.extent, in: bounds.size, margin: Self.fitMargin, topInset: topInset)
        hasFitted = true
        fittedSize = bounds.size
        cameraChanged(synchronous: true)
    }

    private func isCameraFitted(inset: CGFloat) -> Bool {
        guard let page, bounds.width > 0 else { return false }
        let fitted = CanvasCamera.fitting(page.extent, in: bounds.size, margin: Self.fitMargin, topInset: inset)
        return abs(fitted.scale - camera.scale) < 1e-6 && abs(fitted.offset.x - camera.offset.x) < 0.5 && abs(fitted.offset.y - camera.offset.y) < 0.5
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        liveLayer.frame = bounds
        eraserLayer.frame = bounds
        lassoLayer.frame = bounds
        selectionLayer.frame = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        paperLayer.frame = bounds
        markerGroup.frame = bounds
        liveMarkerLayer.bounds = CGRect(origin: .zero, size: bounds.size)
        liveMarkerLayer.position = .zero
        liveMarkerMask.frame = CGRect(origin: .zero, size: bounds.size)
        CATransaction.commit()
        movingCanvas.frame = bounds
        importContainer.frame = bounds
        importMask.frame = bounds
        if !hasFitted || fittedSize != bounds.size {
            fit()
        }
    }

    private func drawMoving(in context: CGContext, rect: CGRect) {
        let moving = movingIds()
        guard !moving.isEmpty, let page else { return }
        let index = currentIndex()
        let isMoving = { (item: RenderIndex.Item) in moving.contains(item.element.id) }
        let shown = RenderIndex(imports: [], markers: index.markers.filter(isMoving), others: index.others.filter(isMoving))
        var options = renderOptions()
        options.fillsOutside = false
        options.drawsPaper = false
        options.drawsImports = false
        options.drawsLines = false
        if let pressedText, isTextLifted {
            options.elementOffsets[pressedText.id] = textOffset
        }
        if selectionOffset != .zero {
            for id in selectedIds {
                options.elementOffsets[id] = selectionOffset
            }
        }
        if let selectionScaleAnchor {
            for id in selectedIds {
                options.elementTransforms[id] = scaling(about: selectionScaleAnchor)
            }
        }
        PageRenderer.draw(page, in: context, camera: camera, visibleRect: rect, options: options, cache: cache, index: shown)
    }

    private func renderOptions() -> RenderOptions {
        RenderOptions(showsGuides: showsGuides, showsDividers: showsDividers, paperStyle: paperStyle, hiddenElementIds: hiddenElementIds.union(pendingErased), pixelScale: pixelScale)
    }

    private func layoutImports() {
        let imports = currentIndex().imports
        let rendersNewLevel = cameraSettleTimer == nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var seen = Set<String>()
        let hidden = hiddenElementIds.union(pendingErased)
        let screenPage = camera.toPage(bounds)
        var shownKeys = Set<String>()
        for element in imports {
            guard let rect = PageRenderer.importRect(for: element) else { continue }
            seen.insert(element.id)
            let sublayer = importLayers[element.id] ?? makeImportLayer(element.id)
            sublayer.bounds = CGRect(origin: .zero, size: rect.size)
            sublayer.position = camera.toScreen(Point(x: Double(rect.minX), y: Double(rect.minY)))
            sublayer.transform = CATransform3DMakeScale(camera.scale, camera.scale, 1)
            sublayer.isHidden = hidden.contains(element.id) || !rect.intersects(screenPage)
            guard !sublayer.isHidden else { continue }
            if let shown = ImportImages.shared.shownImage(for: element, pixelsPerMillimetre: Double(camera.scale * pixelScale), isDark: paperStyle == .dark, rendersNewLevel: rendersNewLevel) {
                shownKeys.insert(shown.key)
                if (sublayer.contents as AnyObject?) !== shown.image {
                    sublayer.contents = shown.image
                }
                sublayer.backgroundColor = nil
            } else {
                sublayer.contents = nil
                sublayer.backgroundColor = UIColor(hex: Palette.paperColors(paperStyle).guide).cgColor
            }
        }
        for (id, sublayer) in importLayers where !seen.contains(id) {
            sublayer.removeFromSuperlayer()
            importLayers[id] = nil
        }
        CATransaction.commit()
        ImportImages.shared.hold(shownKeys, for: ObjectIdentifier(self))
    }

    private func makeImportLayer(_ id: String) -> CALayer {
        let sublayer = CALayer()
        sublayer.anchorPoint = .zero
        sublayer.magnificationFilter = .linear
        sublayer.minificationFilter = .linear
        sublayer.contentsGravity = .resize
        importContainer.addSublayer(sublayer)
        importLayers[id] = sublayer
        return sublayer
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        stopGlide()
        if activeTouch != nil, isFingerTouch, touches.contains(where: { $0.type == .pencil }) {
            restoreTouchCamera()
            cancelActiveGesture()
        }
        guard activeTouch == nil, let touch = touches.first(where: { !palmGuard.isPalm($0) }), let page else { return }
        clearPendingFeedback()
        activeTouch = touch
        touchCamera = camera
        isFingerTouch = touch.type == .direct
        hasMoved = false
        isHolding = false
        gestureStart = touch.location(in: self)
        lastPanLocation = gestureStart
        panSamples = [(gestureStart, touch.timestamp)]
        onInput?()
        let point = camera.toPage(gestureStart)
        onSelectionMenu?(nil)
        let isInsideSelection = selectionScreenRect()?.contains(gestureStart) ?? false
        if !isReadOnly, !selectedIds.isEmpty, isFingerTouch || (isInsideSelection && tool == .lasso) {
            selectionStart = point
            isSelectionTouchInside = isInsideSelection
            return
        }
        if tool == .text, !isReadOnly, let element = textElement(at: point), let box = element.box, let rect = PageRenderer.textRect(for: element) {
            pressedText = PressedText(id: element.id, origin: box, start: point, height: Double(rect.height))
            startTextHoldTimer()
            return
        }
        if isFingerTouch {
            startHoldTimer()
        }
        guard !isReadOnly else {
            isPanning = isFingerTouch
            return
        }
        switch tool {
        case .ink:
            guard !isFingerTouch, Ink.isInsidePaper(point, extent: page.extent) else {
                isPanning = true
                return
            }
            beginStroke(at: gestureStart, point: point)
        case .eraser:
            guard !isFingerTouch else {
                isPanning = true
                return
            }
            lastErasePoint = point
            erase(from: point, to: point)
            showEraser(at: gestureStart)
        case .text:
            isPanning = isFingerTouch
        case .lasso:
            guard !isFingerTouch else {
                isPanning = true
                return
            }
            lassoPoints = [point]
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch), let page else { return }
        if isFingerTouch, palmGuard.isPalm(touch) {
            restoreTouchCamera()
            cancelActiveGesture()
            return
        }
        let location = touch.location(in: self)
        if !hasMoved, hypot(location.x - gestureStart.x, location.y - gestureStart.y) > Self.holdTolerance {
            hasMoved = true
            cancelHoldTimer()
            if pressedText != nil, !isTextLifted {
                cancelTextHoldTimer()
                pressedText = nil
                isPanning = isFingerTouch
            }
        }
        if isHolding {
            onHoldMove?(convert(location, to: nil))
            return
        }
        if isPanning {
            camera.offset.x += location.x - lastPanLocation.x
            camera.offset.y += location.y - lastPanLocation.y
            lastPanLocation = location
            recordPanSample(location, time: touch.timestamp)
            cameraChanged()
            return
        }
        guard !isReadOnly else { return }
        if let selectionStart {
            let point = camera.toPage(location)
            selectionOffset = CGVector(dx: point.x - selectionStart.x, dy: point.y - selectionStart.y)
            showSelection()
            refreshContent()
            return
        }
        if let pressedText {
            guard isTextLifted else { return }
            let point = camera.toPage(location)
            let moved = TextBox(x: pressedText.origin.x + point.x - pressedText.start.x, y: pressedText.origin.y + point.y - pressedText.start.y, width: pressedText.origin.width)
            let box = Ink.clampBox(moved, extent: page.extent, height: pressedText.height)
            textOffset = CGVector(dx: box.x - pressedText.origin.x, dy: box.y - pressedText.origin.y)
            refreshContent()
            return
        }
        let samples = event?.coalescedTouches(for: touch) ?? [touch]
        switch tool {
        case .ink:
            guard stroke != nil else { return }
            for sample in samples {
                let sampleLocation = sample.location(in: self)
                extendStroke(at: sampleLocation, point: camera.toPage(sampleLocation))
            }
            if let stroke, stroke.straightEnd == nil {
                stroke.predicted = (event?.predictedTouches(for: touch) ?? []).prefix(1).map { camera.toPage($0.location(in: self)) }
            }
            updateLiveStroke()
        case .eraser:
            for sample in samples {
                let point = camera.toPage(sample.location(in: self))
                erase(from: lastErasePoint ?? point, to: point)
                lastErasePoint = point
            }
            showEraser(at: location)
        case .text:
            break
        case .lasso:
            for sample in samples {
                lassoPoints.append(camera.toPage(sample.location(in: self)))
            }
            showLasso()
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch), let page else { return }
        cancelHoldTimer()
        cancelTextHoldTimer()
        let location = touch.location(in: self)
        let point = camera.toPage(location)
        let wasHolding = isHolding
        let wasPanning = isPanning
        let wasMoved = hasMoved
        resetGesture()
        hideEraser()
        if wasHolding {
            onHoldEnd?(convert(location, to: nil))
            return
        }
        if selectionStart != nil {
            finishSelectionMove(isMoved: wasMoved)
            return
        }
        if let pressedText {
            if isTextLifted {
                if textOffset != .zero {
                    onTextMove?(pressedText.id, TextBox(x: pressedText.origin.x + Double(textOffset.dx), y: pressedText.origin.y + Double(textOffset.dy), width: pressedText.origin.width))
                } else {
                    clearPendingFeedback()
                    refreshContent()
                }
            } else if !wasMoved {
                self.pressedText = nil
                onTextTap?(point, pressedText.id)
            }
            return
        }
        if wasPanning {
            endStroke()
            liveLayer.path = nil
            liveMarkerLayer.path = nil
            if wasMoved {
                recordPanSample(location, time: touch.timestamp)
                startGlide(panVelocity())
            }
            if tool == .text, !wasMoved, !isReadOnly, Ink.isInsidePaper(point, extent: page.extent) {
                onTextTap?(point, nil)
            }
            return
        }
        guard !isReadOnly else { return }
        switch tool {
        case .ink(let inkTool):
            guard stroke != nil else { return }
            extendStroke(at: location, point: point)
            let points = finalStrokePoints()
            endStroke()
            showLive(points)
            onStroke?(inkTool, inkColor, Ink.clipToPaper(points, extent: page.extent), inkWidth)
        case .eraser:
            lastErasePoint = nil
            if !pendingErased.isEmpty {
                onErase?(pendingErased)
            }
            if !areaErase.isEmpty {
                let replacements = areaErase.map { StrokeReplacement(elementId: $0.key, pieces: $0.value.pieces) }
                areaErase = [:]
                onEraseArea?(replacements)
            }
            if touch.type == .pencil {
                onEraseLift?()
            }
        case .text:
            if !wasMoved, Ink.isInsidePaper(point, extent: page.extent) {
                onTextTap?(point, nil)
            }
        case .lasso:
            finishLasso(isMoved: wasMoved)
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        cancelActiveGesture()
    }

    private func cancelActiveGesture() {
        cancelHoldTimer()
        cancelTextHoldTimer()
        if isHolding {
            onHoldEnd?(CGPoint(x: -1, y: -1))
        }
        endStroke()
        liveLayer.path = nil
        liveMarkerLayer.path = nil
        lastErasePoint = nil
        lassoPoints = []
        lassoLayer.path = nil
        selectionStart = nil
        selectionOffset = .zero
        showSelection()
        hideEraser()
        clearPendingFeedback()
        resetGesture()
        refreshContent()
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        gestureRecognizer is PalmWatchGestureRecognizer || !palmGuard.isPalm(touch)
    }

    private func restoreTouchCamera() {
        guard let touchCamera, isPanning else { return }
        camera = touchCamera
        self.touchCamera = nil
        cameraChanged()
    }

    private func trackGestureCamera(_ state: UIGestureRecognizer.State) {
        if state == .cancelled || state == .failed {
            stopGlide()
        }
    }

    func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
        onPencilTap?()
    }

    @objc private func handleUndoTap() {
        onUndo?()
    }

    @objc private func handleRedoTap() {
        onRedo?()
    }

    @objc private func handlePinch(_ pinch: UIPinchGestureRecognizer) {
        trackGestureCamera(pinch.state)
        if pinch.state == .began {
            onSelectionMenu?(nil)
            if !isReadOnly, let selectionBounds, selectionScreenRect()?.contains(pinch.location(in: self)) ?? false {
                selectionScaleAnchor = CGPoint(x: selectionBounds.midX, y: selectionBounds.midY)
                selectionScale = 1
            }
        }
        if selectionScaleAnchor != nil {
            scaleSelection(with: pinch)
            return
        }
        guard pinch.state == .began || pinch.state == .changed else { return }
        stopGlide()
        if activeTouch != nil {
            cancelActiveGesture()
        }
        let smallest = page.map { CanvasCamera.smallestScale(for: $0.extent, in: bounds.size, margin: Self.fitMargin, topInset: topInset) } ?? 0
        let factor = max(pinch.scale, smallest / camera.scale)
        if abs(factor - 1) > 1e-6 {
            camera = camera.zoomed(by: factor, around: pinch.location(in: self))
        }
        pinch.scale = 1
        cameraChanged()
    }

    private func scaleSelection(with pinch: UIPinchGestureRecognizer) {
        switch pinch.state {
        case .began, .changed:
            if activeTouch != nil {
                cancelActiveGesture()
            }
            selectionScale = min(Self.selectionScaleRange.upperBound, max(Self.selectionScaleRange.lowerBound, selectionScale * pinch.scale))
            pinch.scale = 1
            showSelection()
            refreshContent()
        case .ended:
            finishSelectionScale()
        default:
            selectionScaleAnchor = nil
            selectionScale = 1
            showSelection()
            refreshContent()
        }
    }

    private func scaling(about anchor: CGPoint) -> CGAffineTransform {
        CGAffineTransform(translationX: anchor.x, y: anchor.y).scaledBy(x: selectionScale, y: selectionScale).translatedBy(x: -anchor.x, y: -anchor.y)
    }

    private func finishSelectionScale() {
        guard let anchor = selectionScaleAnchor else { return }
        let factor = Double(selectionScale)
        selectionScaleAnchor = nil
        selectionScale = 1
        if abs(factor - 1) > 0.001 {
            Haptics.landed()
            onScaleElements?(selectedIds, Point(x: Double(anchor.x), y: Double(anchor.y)), factor)
        }
        refreshSelection()
        refreshContent()
    }

    @objc private func handlePan(_ pan: UIPanGestureRecognizer) {
        trackGestureCamera(pan.state)
        if pan.state == .began {
            stopGlide()
        }
        if pan.state == .ended, selectionScaleAnchor == nil {
            startGlide(pan.velocity(in: self))
            return
        }
        guard pan.state == .began || pan.state == .changed, selectionScaleAnchor == nil else { return }
        if activeTouch != nil {
            cancelActiveGesture()
        }
        let translation = pan.translation(in: self)
        camera.offset.x += translation.x
        camera.offset.y += translation.y
        pan.setTranslation(.zero, in: self)
        cameraChanged()
    }

    private func recordPanSample(_ location: CGPoint, time: TimeInterval) {
        panSamples.append((location, time))
        panSamples.removeAll { time - $0.time > Self.glideSampleWindow }
    }

    private func panVelocity() -> CGPoint {
        guard let first = panSamples.first, let last = panSamples.last, last.time - first.time > 0.001 else { return .zero }
        let elapsed = CGFloat(last.time - first.time)
        return CGPoint(x: (last.location.x - first.location.x) / elapsed, y: (last.location.y - first.location.y) / elapsed)
    }

    private func startGlide(_ velocity: CGPoint) {
        stopGlide()
        guard hypot(velocity.x, velocity.y) > Self.glideStopSpeed else { return }
        glideVelocity = velocity
        glideLast = CACurrentMediaTime()
        let link = CADisplayLink(target: DisplayLinkTarget { [weak self] in self?.stepGlide() }, selector: #selector(DisplayLinkTarget.step))
        link.add(to: .main, forMode: .common)
        glideLink = link
    }

    private func stopGlide() {
        glideLink?.invalidate()
        glideLink = nil
        glideVelocity = .zero
    }

    private func stepGlide() {
        let now = CACurrentMediaTime()
        let elapsed = CGFloat(now - glideLast)
        glideLast = now
        let before = camera.offset
        camera.offset.x += glideVelocity.x * elapsed
        camera.offset.y += glideVelocity.y * elapsed
        cameraChanged()
        let retained = CGFloat(pow(Motion.shares.panGlideDecay, Double(elapsed * 1000)))
        glideVelocity.x = camera.offset.x == before.x ? 0 : glideVelocity.x * retained
        glideVelocity.y = camera.offset.y == before.y ? 0 : glideVelocity.y * retained
        if hypot(glideVelocity.x, glideVelocity.y) < Self.glideStopSpeed {
            stopGlide()
        }
    }

    private func cameraChanged(synchronous: Bool = false) {
        cameraSettleTimer?.invalidate()
        cameraSettleTimer = Timer.scheduledTimer(withTimeInterval: Self.cameraSettleSeconds, repeats: false) { [weak self] _ in
            self?.cameraSettleTimer = nil
            self?.layoutImports()
        }
        if let page {
            camera = camera.constrained(to: page.extent, in: bounds.size, margin: Self.fitMargin, topInset: topInset)
        }
        layoutPaper()
        if stroke != nil {
            updateLiveStroke()
        } else {
            liveLayer.path = nil
            liveMarkerLayer.path = nil
        }
        showLasso()
        showSelection()
        layoutImports()
        updateTiles(synchronous: synchronous)
        if !movingCanvas.isHidden {
            movingCanvas.setNeedsDisplay()
        }
        onCameraChange?(camera)
    }

    private func beginStroke(at location: CGPoint, point: Point) {
        endStroke()
        stroke = StrokeSession(location: location, point: point)
        restartStill(at: location)
        showLive([point])
    }

    private func extendStroke(at location: CGPoint, point: Point) {
        guard let stroke else { return }
        if stroke.straightEnd != nil {
            stroke.straightEnd = point
            return
        }
        let travelled = hypot(location.x - stroke.lastLocation.x, location.y - stroke.lastLocation.y)
        guard travelled >= Self.minimumSampleSpacing else { return }
        stroke.screenLength += travelled
        stroke.lastLocation = location
        stroke.raw.append(point)
        if hypot(location.x - stroke.stillLocation.x, location.y - stroke.stillLocation.y) > CGFloat(Tokens.shared.ink.straightenTolerancePoints) {
            restartStill(at: location)
        }
    }

    private func restartStill(at location: CGPoint) {
        guard let stroke else { return }
        stroke.stillTimer?.invalidate()
        stroke.stillLocation = location
        stroke.stillTimer = Timer.scheduledTimer(withTimeInterval: Motion.seconds(Tokens.shared.motion.durations.strokeStraightenHold), repeats: false) { [weak self] _ in
            self?.straightenStroke()
        }
    }

    private func straightenStroke() {
        guard let stroke, stroke.straightEnd == nil, stroke.screenLength >= Self.minimumStraightLength else { return }
        stroke.straightEnd = stroke.raw.last
        stroke.straightShare = 0
        stroke.predicted = []
        Haptics.segment()
        snapLink?.invalidate()
        snapStart = CACurrentMediaTime()
        let link = CADisplayLink(target: DisplayLinkTarget { [weak self] in self?.stepSnap() }, selector: #selector(DisplayLinkTarget.step))
        link.add(to: .main, forMode: .common)
        snapLink = link
    }

    private func stepSnap() {
        guard let stroke else {
            snapLink?.invalidate()
            snapLink = nil
            return
        }
        let progress = min(1, (CACurrentMediaTime() - snapStart) / Motion.seconds(Tokens.shared.motion.durations.strokeStraightenSnap))
        let inverse = 1 - progress
        stroke.straightShare = 1 - inverse * inverse
        updateLiveStroke()
        if progress >= 1 {
            snapLink?.invalidate()
            snapLink = nil
        }
    }

    private func snappedEnd(_ stroke: StrokeSession) -> Point {
        Ink.axisSnapped(start: stroke.raw[0], end: stroke.straightEnd ?? stroke.raw[stroke.raw.count - 1], degrees: Tokens.shared.ink.straightenAxisSnapDegrees)
    }

    private func liveStrokePoints() -> [Point] {
        guard let stroke else { return [] }
        let smooth = Ink.smoothStroke(stroke.raw + stroke.predicted, scale: Double(camera.scale), settings: InkStyle.settings(smoothing: inkSmoothing))
        guard stroke.straightEnd != nil else { return smooth }
        return Ink.straightened(smooth, start: stroke.raw[0], end: snappedEnd(stroke), share: stroke.straightShare)
    }

    private func finalStrokePoints() -> [Point] {
        guard let stroke else { return [] }
        if stroke.straightEnd != nil {
            return Ink.smoothStroke([stroke.raw[0], snappedEnd(stroke)], scale: Double(camera.scale), settings: InkStyle.settings(smoothing: inkSmoothing))
        }
        let ink = Tokens.shared.ink
        if tool == .ink(.marker), let line = Ink.fittedLine(stroke.raw, minimumLength: ink.markerStraightenLength, deviationShare: ink.markerStraightenDeviation, detourShare: ink.markerStraightenDetour) {
            return Ink.smoothStroke([line.start, line.end], scale: Double(camera.scale), settings: InkStyle.settings(smoothing: inkSmoothing))
        }
        return Ink.smoothStroke(stroke.raw, scale: Double(camera.scale), settings: InkStyle.settings(smoothing: inkSmoothing))
    }

    private func endStroke() {
        stroke?.stillTimer?.invalidate()
        snapLink?.invalidate()
        snapLink = nil
        stroke = nil
    }

    private func updateLiveStroke() {
        showLive(liveStrokePoints())
    }

    private func showLive(_ points: [Point]) {
        guard case .ink(let inkTool) = tool else { return }
        let style = InkStyle.tokens(for: inkTool)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let isMarker = inkTool == .marker
        let shown = isMarker ? liveMarkerLayer : liveLayer
        let color = UIColor(hex: Palette.inkOnPaper(inkColor, style: paperStyle))
        shown.lineWidth = CGFloat(inkWidth) * camera.scale
        shown.strokeColor = (isMarker ? color : color.withAlphaComponent(CGFloat(style.opacity))).cgColor
        shown.path = StrokePathCache.makePath(points, transform: camera.toScreen)
        CATransaction.commit()
    }

    private func eraserReach() -> Double {
        max(eraserRadius, Double(Self.minimumEraserReach / camera.scale))
    }

    private func showEraser(at location: CGPoint) {
        let radius = CGFloat(eraserReach()) * camera.scale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        eraserLayer.path = CGPath(ellipseIn: CGRect(x: location.x - radius, y: location.y - radius, width: radius * 2, height: radius * 2), transform: nil)
        CATransaction.commit()
    }

    private func hideEraser() {
        eraserLayer.path = nil
    }

    private func erase(from sweepStart: Point, to sweepEnd: Point) {
        guard let page, case .eraser(let mode) = tool else { return }
        let reach = eraserReach()
        var erased = CGRect.null
        let index = currentIndex()
        let sweep = CGRect(x: min(sweepStart.x, sweepEnd.x), y: min(sweepStart.y, sweepEnd.y), width: abs(sweepEnd.x - sweepStart.x), height: abs(sweepEnd.y - sweepStart.y)).insetBy(dx: -reach, dy: -reach)
        for item in index.markers + index.others where item.element.type == .stroke && item.bounds.intersects(sweep) {
            let element = item.element
            guard let points = element.points, !points.isEmpty else { continue }
            let strokeReach = reach + (element.width ?? 0) / 2
            if mode == .area {
                let entry = areaErase[element.id]
                let pieces = entry?.pieces ?? [points]
                var isTouched = false
                var nextPieces: [[Point]] = []
                for piece in pieces {
                    if let cut = Ink.cutStroke(piece, from: sweepStart, to: sweepEnd, reach: strokeReach) {
                        isTouched = true
                        nextPieces.append(contentsOf: cut)
                    } else {
                        nextPieces.append(piece)
                    }
                }
                if isTouched {
                    areaErase[element.id] = AreaEntry(element: element, pieces: nextPieces, revision: (entry?.revision ?? 0) + 1)
                    erased = erased.union(item.bounds)
                }
            } else if !pendingErased.contains(element.id), Ink.isStrokeSwept(element, from: sweepStart, to: sweepEnd, radius: reach) {
                pendingErased.append(element.id)
                erased = erased.union(item.bounds)
            }
        }
        if !erased.isNull {
            Haptics.segment()
            refreshContent()
        }
    }

    private func showLasso() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if lassoPoints.count < 2 {
            lassoLayer.path = nil
        } else {
            let path = CGMutablePath()
            path.addLines(between: lassoPoints.map(camera.toScreen))
            path.closeSubpath()
            lassoLayer.path = path
        }
        CATransaction.commit()
    }

    private func finishLasso(isMoved: Bool) {
        let polygon = lassoPoints
        lassoPoints = []
        lassoLayer.path = nil
        guard isMoved, polygon.count >= 3, let page else {
            clearSelection()
            return
        }
        selectedIds = page.liveElements.filter { isEnclosed($0, by: polygon) }.map(\.id)
        if !selectedIds.isEmpty {
            Haptics.segment()
        }
        refreshSelection()
    }

    private func isEnclosed(_ element: Element, by polygon: [Point]) -> Bool {
        switch element.type {
        case .stroke:
            return Lasso.touches(polygon, line: element.points ?? [])
        case .importPage:
            return false
        case .text:
            guard let rect = Self.elementBounds(element) else { return false }
            let corners = [Point(x: rect.minX, y: rect.minY), Point(x: rect.maxX, y: rect.minY), Point(x: rect.maxX, y: rect.maxY), Point(x: rect.minX, y: rect.maxY)]
            return Lasso.touches(polygon, area: corners)
        }
    }

    static func elementBounds(_ element: Element) -> CGRect? {
        switch element.type {
        case .stroke:
            guard let points = element.points, let bounds = StrokeGeometry.bounds(of: points) else { return nil }
            let reach = (element.width ?? 0) / 2
            return CGRect(x: bounds.minimumX - reach, y: bounds.minimumY - reach, width: bounds.maximumX - bounds.minimumX + reach * 2, height: bounds.maximumY - bounds.minimumY + reach * 2)
        case .text:
            return PageRenderer.textRect(for: element)
        case .importPage:
            return PageRenderer.importRect(for: element)
        }
    }

    private func refreshSelection() {
        guard let page, !selectedIds.isEmpty else {
            selectionBounds = nil
            showSelection()
            return
        }
        let live = page.liveElements.filter { selectedIds.contains($0.id) }
        selectedIds = live.map(\.id)
        selectionBounds = live.compactMap(Self.elementBounds).reduce(CGRect?.none) { union, rect in union.map { $0.union(rect) } ?? rect }
        showSelection()
    }

    private func selectionScreenRect() -> CGRect? {
        guard let selectionBounds else { return nil }
        var moved = selectionBounds.offsetBy(dx: selectionOffset.dx, dy: selectionOffset.dy)
        if let selectionScaleAnchor {
            moved = moved.applying(scaling(about: selectionScaleAnchor))
        }
        let origin = camera.toScreen(Point(x: moved.minX, y: moved.minY))
        return CGRect(x: origin.x, y: origin.y, width: moved.width * camera.scale, height: moved.height * camera.scale).insetBy(dx: -Self.selectionPadding, dy: -Self.selectionPadding)
    }

    private func showSelection() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        selectionLayer.path = selectionScreenRect().map { CGPath(roundedRect: $0, cornerWidth: Self.selectionPadding, cornerHeight: Self.selectionPadding, transform: nil) }
        CATransaction.commit()
    }

    private func finishSelectionMove(isMoved: Bool) {
        let offset = selectionOffset
        selectionStart = nil
        selectionOffset = .zero
        if isMoved, offset != .zero {
            Haptics.landed()
            onMoveElements?(selectedIds, Point(x: Double(offset.dx), y: Double(offset.dy)))
        } else if !isMoved, isSelectionTouchInside, let rect = selectionScreenRect() {
            onSelectionMenu?(SelectionMenuRequest(ids: selectedIds, frame: convert(rect, to: nil)))
        } else if !isMoved {
            clearSelection()
        }
        refreshSelection()
        refreshContent()
    }

    private func clearSelection() {
        selectedIds = []
        onSelectionMenu?(nil)
        refreshSelection()
    }

    private func textElement(at point: Point) -> Element? {
        page?.liveElements.reversed().first { element in
            guard let rect = PageRenderer.textRect(for: element) else { return false }
            return rect.insetBy(dx: -2, dy: -2).contains(CGPoint(x: point.x, y: point.y))
        }
    }

    private func startTextHoldTimer() {
        cancelTextHoldTimer()
        textHoldTimer = Timer.scheduledTimer(withTimeInterval: Motion.seconds(Motion.textMoveHoldMilliseconds), repeats: false) { [weak self] _ in
            guard let self, self.pressedText != nil, !self.hasMoved else { return }
            self.isTextLifted = true
            Haptics.hold()
        }
    }

    private func cancelTextHoldTimer() {
        textHoldTimer?.invalidate()
        textHoldTimer = nil
    }

    private func startHoldTimer() {
        cancelHoldTimer()
        holdTimer = Timer.scheduledTimer(withTimeInterval: Motion.seconds(Motion.menuHoldMilliseconds), repeats: false) { [weak self] _ in
            self?.beginHold()
        }
    }

    private func cancelHoldTimer() {
        holdTimer?.invalidate()
        holdTimer = nil
    }

    private func beginHold() {
        guard let activeTouch, !hasMoved, !palmGuard.isPalm(activeTouch) else { return }
        isHolding = true
        isPanning = false
        endStroke()
        liveLayer.path = nil
        liveMarkerLayer.path = nil
        lassoPoints = []
        lassoLayer.path = nil
        clearPendingFeedback()
        refreshContent()
        Haptics.hold()
        onHold?(convert(gestureStart, to: nil), camera.toPage(gestureStart))
    }

    private func clearPendingFeedback() {
        pendingErased = []
        areaErase = [:]
        pressedText = nil
        isTextLifted = false
        textOffset = .zero
        if stroke == nil {
            liveLayer.path = nil
            liveMarkerLayer.path = nil
        }
    }

    private func resetGesture() {
        activeTouch = nil
        isHolding = false
        isPanning = false
        hasMoved = false
    }
}

final class DisplayLinkTarget: NSObject {
    private let action: () -> Void

    init(_ action: @escaping () -> Void) {
        self.action = action
    }

    @objc func step() {
        action()
    }
}
