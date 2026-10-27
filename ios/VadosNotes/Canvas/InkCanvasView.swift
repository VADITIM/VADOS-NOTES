import NotesCore
import QuartzCore
import UIKit

enum CanvasTool: Equatable {
    case ink(Tool)
    case eraser(EraserMode)
    case text
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

final class InkCanvasView: UIView, UIGestureRecognizerDelegate {
    var page: Page? {
        didSet {
            guard page != oldValue else { return }
            if oldValue?.id != page?.id {
                hasFitted = false
                setNeedsLayout()
            }
            clearPendingFeedback()
            setNeedsDisplay()
        }
    }
    var tool: CanvasTool = .ink(.pen)
    var inkColor = "#1A1A1A"
    var inkWidth = 0.5
    var eraserRadius = 2.0
    var isReadOnly = false
    var paperStyle: PaperStyle = .dark {
        didSet { if paperStyle != oldValue { setNeedsDisplay() } }
    }
    var showsGuides = true {
        didSet { if showsGuides != oldValue { setNeedsDisplay() } }
    }
    var showsDividers = true {
        didSet { if showsDividers != oldValue { setNeedsDisplay() } }
    }
    var hiddenElementIds: Set<String> = [] {
        didSet { if hiddenElementIds != oldValue { setNeedsDisplay() } }
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
    var onInput: (() -> Void)?
    var onHold: ((CGPoint) -> Void)?
    var onHoldMove: ((CGPoint) -> Void)?
    var onHoldEnd: ((CGPoint) -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?

    private(set) var camera = CanvasCamera()
    private let cache = StrokePathCache()
    private let liveLayer = CAShapeLayer()
    private let liveMask = CAShapeLayer()
    private let eraserLayer = CAShapeLayer()
    private var activeTouch: UITouch?
    private var stroke: StrokeSession?
    private var snapLink: CADisplayLink?
    private var snapStart: CFTimeInterval = 0
    private var lastErasePoint: Point?
    private var gestureStart: CGPoint = .zero
    private var lastPanLocation: CGPoint = .zero
    private var hasMoved = false
    private var holdTimer: Timer?
    private var isHolding = false
    private var hasSeenPencil = false
    private var isPanning = false
    private var pendingErased: [String] = []
    private var areaErase: [String: AreaEntry] = [:]
    private var movingText: (id: String, origin: TextBox, start: Point, height: Double)?
    private var textOffset: CGVector = .zero
    private var hasFitted = false
    private var fittedSize: CGSize = .zero
    private var importObserver: NSObjectProtocol?

    private static let fitMargin: CGFloat = 24
    private static let holdTolerance: CGFloat = 8
    private static let minimumEraserReach: CGFloat = 6
    private static let minimumSampleSpacing: CGFloat = 0.25
    private static let minimumStraightLength: CGFloat = 24

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = Palette.outside
        contentMode = .redraw
        liveLayer.fillColor = nil
        liveLayer.lineCap = .round
        liveLayer.lineJoin = .round
        liveLayer.mask = liveMask
        layer.addSublayer(liveLayer)
        eraserLayer.fillColor = UIColor(Palette.destructive).withAlphaComponent(0.12).cgColor
        eraserLayer.strokeColor = UIColor(Palette.destructive).withAlphaComponent(0.9).cgColor
        eraserLayer.lineWidth = 1.5
        layer.addSublayer(eraserLayer)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        pinch.delegate = self
        addGestureRecognizer(pinch)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        pan.delegate = self
        addGestureRecognizer(pan)

        let undoTap = UITapGestureRecognizer(target: self, action: #selector(handleUndoTap))
        undoTap.numberOfTouchesRequired = 2
        undoTap.numberOfTapsRequired = 2
        undoTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        undoTap.delegate = self
        addGestureRecognizer(undoTap)

        let redoTap = UITapGestureRecognizer(target: self, action: #selector(handleRedoTap))
        redoTap.numberOfTouchesRequired = 3
        redoTap.numberOfTapsRequired = 2
        redoTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        redoTap.delegate = self
        addGestureRecognizer(redoTap)

        importObserver = NotificationCenter.default.addObserver(forName: ImportImages.didRender, object: nil, queue: .main) { [weak self] _ in
            self?.setNeedsDisplay()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("InkCanvasView is created in code")
    }

    deinit {
        if let importObserver {
            NotificationCenter.default.removeObserver(importObserver)
        }
    }

    func fit() {
        guard let page, bounds.width > 0 else { return }
        camera = CanvasCamera.fitting(page.extent, in: bounds.size, margin: Self.fitMargin, topInset: topInset)
        hasFitted = true
        fittedSize = bounds.size
        cameraChanged()
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
        if !hasFitted || fittedSize != bounds.size {
            fit()
        }
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), var page else { return }
        var options = RenderOptions(showsGuides: showsGuides, showsDividers: showsDividers, paperStyle: paperStyle, hiddenElementIds: hiddenElementIds.union(pendingErased), pixelScale: window?.screen.scale ?? 2)
        if let movingText {
            options.textOffsets[movingText.id] = textOffset
        }
        if !areaErase.isEmpty {
            var elements = page.elements.filter { areaErase[$0.id] == nil }
            for (elementId, entry) in areaErase {
                for (index, points) in entry.pieces.enumerated() {
                    var piece = entry.element
                    piece.id = "\(elementId)-piece-\(index)-\(entry.revision)"
                    piece.points = points
                    elements.append(piece)
                }
            }
            page.elements = elements
        }
        PageRenderer.draw(page, in: context, camera: camera, visibleRect: bounds, options: options, cache: cache)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard activeTouch == nil, let touch = touches.first, let page else { return }
        let isFinger = touch.type != .pencil
        if !isFinger {
            hasSeenPencil = true
        }
        clearPendingFeedback()
        activeTouch = touch
        hasMoved = false
        isHolding = false
        gestureStart = touch.location(in: self)
        lastPanLocation = gestureStart
        onInput?()
        if isFinger {
            startHoldTimer()
            if hasSeenPencil {
                isPanning = true
                return
            }
        }
        guard !isReadOnly else { return }
        let point = camera.toPage(gestureStart)
        switch tool {
        case .ink:
            guard Ink.isInsidePaper(point, extent: page.extent) else {
                isPanning = true
                return
            }
            beginStroke(at: gestureStart, point: point)
        case .eraser:
            lastErasePoint = point
            erase(from: point, to: point)
            showEraser(at: gestureStart)
        case .text:
            if let element = textElement(at: point), let box = element.box, let rect = PageRenderer.textRect(for: element) {
                movingText = (element.id, box, point, Double(rect.height))
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch), let page else { return }
        let location = touch.location(in: self)
        if hypot(location.x - gestureStart.x, location.y - gestureStart.y) > Self.holdTolerance {
            hasMoved = true
            cancelHoldTimer()
        }
        if isHolding {
            onHoldMove?(convert(location, to: nil))
            return
        }
        if isPanning {
            camera.offset.x += location.x - lastPanLocation.x
            camera.offset.y += location.y - lastPanLocation.y
            lastPanLocation = location
            cameraChanged()
            return
        }
        guard !isReadOnly else { return }
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
            guard let movingText, hasMoved else { return }
            let point = camera.toPage(location)
            let moved = TextBox(x: movingText.origin.x + point.x - movingText.start.x, y: movingText.origin.y + point.y - movingText.start.y, width: movingText.origin.width)
            let box = Ink.clampBox(moved, extent: page.extent, height: movingText.height)
            textOffset = CGVector(dx: box.x - movingText.origin.x, dy: box.y - movingText.origin.y)
            setNeedsDisplay()
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch), let page else { return }
        cancelHoldTimer()
        let location = touch.location(in: self)
        let wasHolding = isHolding
        let wasPanning = isPanning
        resetGesture()
        hideEraser()
        if wasHolding {
            onHoldEnd?(convert(location, to: nil))
            return
        }
        if wasPanning || isReadOnly {
            endStroke()
            liveLayer.path = nil
            return
        }
        switch tool {
        case .ink(let inkTool):
            guard stroke != nil else { return }
            extendStroke(at: location, point: camera.toPage(location))
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
        case .text:
            let point = camera.toPage(location)
            if let movingText {
                if textOffset != .zero {
                    onTextMove?(movingText.id, TextBox(x: movingText.origin.x + Double(textOffset.dx), y: movingText.origin.y + Double(textOffset.dy), width: movingText.origin.width))
                } else {
                    self.movingText = nil
                    onTextTap?(point, movingText.id)
                }
            } else if Ink.isInsidePaper(point, extent: page.extent) {
                onTextTap?(point, nil)
            }
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        cancelActiveGesture()
    }

    private func cancelActiveGesture() {
        cancelHoldTimer()
        if isHolding {
            onHoldEnd?(CGPoint(x: -1, y: -1))
        }
        endStroke()
        liveLayer.path = nil
        lastErasePoint = nil
        hideEraser()
        clearPendingFeedback()
        resetGesture()
        setNeedsDisplay()
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }

    @objc private func handleUndoTap() {
        onUndo?()
    }

    @objc private func handleRedoTap() {
        onRedo?()
    }

    @objc private func handlePinch(_ pinch: UIPinchGestureRecognizer) {
        guard pinch.state == .began || pinch.state == .changed else { return }
        if activeTouch != nil {
            cancelActiveGesture()
        }
        camera = camera.zoomed(by: pinch.scale, around: pinch.location(in: self))
        pinch.scale = 1
        cameraChanged()
    }

    @objc private func handlePan(_ pan: UIPanGestureRecognizer) {
        guard pan.state == .began || pan.state == .changed else { return }
        if activeTouch != nil {
            cancelActiveGesture()
        }
        let translation = pan.translation(in: self)
        camera.offset.x += translation.x
        camera.offset.y += translation.y
        pan.setTranslation(.zero, in: self)
        cameraChanged()
    }

    private func cameraChanged() {
        if let page {
            camera = camera.constrained(to: page.extent, in: bounds.size, margin: Self.fitMargin, topInset: topInset)
            let radius = CGFloat(Tokens.shared.page.cornerRadius) * camera.scale
            let paper = CGRect(x: camera.offset.x, y: camera.offset.y, width: CGFloat(PaperGeometry.width(of: page.extent)) * camera.scale, height: CGFloat(PaperGeometry.height(of: page.extent)) * camera.scale)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            liveMask.path = CGPath(roundedRect: paper, cornerWidth: radius, cornerHeight: radius, transform: nil)
            CATransaction.commit()
        }
        if stroke != nil {
            updateLiveStroke()
        } else {
            liveLayer.path = nil
        }
        setNeedsDisplay()
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
        let link = CADisplayLink(target: self, selector: #selector(stepSnap))
        link.add(to: .main, forMode: .common)
        snapLink = link
    }

    @objc private func stepSnap() {
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
        let smooth = Ink.smoothStroke(stroke.raw + stroke.predicted, scale: Double(camera.scale), settings: InkStyle.settings)
        guard stroke.straightEnd != nil else { return smooth }
        return Ink.straightened(smooth, start: stroke.raw[0], end: snappedEnd(stroke), share: stroke.straightShare)
    }

    private func finalStrokePoints() -> [Point] {
        guard let stroke else { return [] }
        if stroke.straightEnd != nil {
            return Ink.smoothStroke([stroke.raw[0], snappedEnd(stroke)], scale: Double(camera.scale), settings: InkStyle.settings)
        }
        return Ink.smoothStroke(stroke.raw, scale: Double(camera.scale), settings: InkStyle.settings)
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
        liveLayer.lineWidth = CGFloat(inkWidth) * camera.scale
        liveLayer.strokeColor = UIColor(hex: Palette.inkOnPaper(inkColor, style: paperStyle)).withAlphaComponent(CGFloat(style.opacity)).cgColor
        liveLayer.path = StrokePathCache.makePath(points, transform: camera.toScreen)
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
        var didErase = false
        for element in page.liveElements where element.type == .stroke {
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
                    didErase = true
                }
            } else if !pendingErased.contains(element.id), Ink.isStrokeSwept(element, from: sweepStart, to: sweepEnd, radius: reach) {
                pendingErased.append(element.id)
                didErase = true
            }
        }
        if didErase {
            Haptics.segment()
            setNeedsDisplay()
        }
    }

    private func textElement(at point: Point) -> Element? {
        page?.liveElements.reversed().first { element in
            guard let rect = PageRenderer.textRect(for: element) else { return false }
            return rect.insetBy(dx: -2, dy: -2).contains(CGPoint(x: point.x, y: point.y))
        }
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
        guard activeTouch != nil, !hasMoved else { return }
        isHolding = true
        isPanning = false
        endStroke()
        liveLayer.path = nil
        clearPendingFeedback()
        setNeedsDisplay()
        Haptics.hold()
        onHold?(convert(gestureStart, to: nil))
    }

    private func clearPendingFeedback() {
        pendingErased = []
        areaErase = [:]
        movingText = nil
        textOffset = .zero
        if stroke == nil {
            liveLayer.path = nil
        }
    }

    private func resetGesture() {
        activeTouch = nil
        isHolding = false
        isPanning = false
        hasMoved = false
    }
}
