import NotesCore
import UIKit

enum CanvasTool: Equatable {
    case ink(Tool)
    case eraser
    case text
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
    var isReadOnly = false
    var showsGuides = true {
        didSet { if showsGuides != oldValue { setNeedsDisplay() } }
    }
    var hiddenElementIds: Set<String> = [] {
        didSet { if hiddenElementIds != oldValue { setNeedsDisplay() } }
    }

    var onCameraChange: ((CanvasCamera) -> Void)?
    var onStroke: ((Tool, String, [Point]) -> Void)?
    var onErase: (([String]) -> Void)?
    var onTextTap: ((Point, String?) -> Void)?
    var onTextMove: ((String, TextBox) -> Void)?
    var onInput: (() -> Void)?
    var onHold: ((CGPoint) -> Void)?
    var onHoldMove: ((CGPoint) -> Void)?
    var onHoldEnd: ((CGPoint) -> Void)?

    private(set) var camera = CanvasCamera()
    private let cache = StrokePathCache()
    private let liveLayer = CAShapeLayer()
    private var activeTouch: UITouch?
    private var livePoints: [Point] = []
    private var gestureStart: CGPoint = .zero
    private var lastPanLocation: CGPoint = .zero
    private var hasMoved = false
    private var holdTimer: Timer?
    private var isHolding = false
    private var hasSeenPencil = false
    private var isPanningWithFinger = false
    private var pendingErased: [String] = []
    private var movingText: (id: String, origin: TextBox, start: Point)?
    private var textOffset: CGVector = .zero
    private var hasFitted = false
    private var fittedSize: CGSize = .zero

    private static let fitMargin: CGFloat = 24
    private static let holdTolerance: CGFloat = 8
    private static let minimumEraserReach: CGFloat = 6

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = Palette.outside
        contentMode = .redraw
        liveLayer.fillColor = nil
        liveLayer.lineCap = .round
        liveLayer.lineJoin = .round
        layer.addSublayer(liveLayer)

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
    }

    required init?(coder: NSCoder) {
        fatalError("InkCanvasView is created in code")
    }

    func fit() {
        guard let page, bounds.width > 0 else { return }
        camera = CanvasCamera.fitting(page.extent, in: bounds.size, margin: Self.fitMargin)
        hasFitted = true
        fittedSize = bounds.size
        cameraChanged()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        liveLayer.frame = bounds
        if !hasFitted || fittedSize != bounds.size {
            fit()
        }
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), let page else { return }
        var options = RenderOptions(showsGuides: showsGuides, hiddenElementIds: hiddenElementIds.union(pendingErased))
        if let movingText {
            options.textOffsets[movingText.id] = textOffset
        }
        PageRenderer.draw(page, in: context, camera: camera, visibleRect: bounds, options: options, cache: cache)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard activeTouch == nil, let touch = touches.first else { return }
        let isFinger = touch.type != .pencil
        if !isFinger {
            hasSeenPencil = true
        }
        clearPendingFeedback()
        activeTouch = touch
        hasMoved = false
        isHolding = false
        gestureStart = touch.location(in: self)
        onInput?()
        if isFinger {
            startHoldTimer()
        }
        if isFinger && hasSeenPencil {
            isPanningWithFinger = true
            lastPanLocation = gestureStart
            return
        }
        guard !isReadOnly else { return }
        let point = camera.toPage(gestureStart)
        switch tool {
        case .ink:
            livePoints = [StrokeGeometry.rounded(point)]
            updateLiveStroke(predicted: [])
        case .eraser:
            erase(at: gestureStart)
        case .text:
            if let element = textElement(at: point), let box = element.box {
                movingText = (element.id, box, point)
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        let location = touch.location(in: self)
        if hypot(location.x - gestureStart.x, location.y - gestureStart.y) > Self.holdTolerance {
            hasMoved = true
            cancelHoldTimer()
        }
        if isHolding {
            onHoldMove?(convert(location, to: nil))
            return
        }
        if isPanningWithFinger {
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
            for sample in samples {
                let point = StrokeGeometry.rounded(camera.toPage(sample.location(in: self)))
                if StrokeGeometry.shouldAppend(point, after: livePoints.last) {
                    livePoints.append(point)
                }
            }
            let predicted = (event?.predictedTouches(for: touch) ?? []).map { camera.toPage($0.location(in: self)) }
            updateLiveStroke(predicted: predicted)
        case .eraser:
            for sample in samples {
                erase(at: sample.location(in: self))
            }
        case .text:
            guard let movingText, hasMoved else { return }
            let point = camera.toPage(location)
            textOffset = CGVector(dx: point.x - movingText.start.x, dy: point.y - movingText.start.y)
            setNeedsDisplay()
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        cancelHoldTimer()
        let location = touch.location(in: self)
        defer { resetGesture() }
        if isHolding {
            onHoldEnd?(convert(location, to: nil))
            return
        }
        if isPanningWithFinger || isReadOnly {
            livePoints = []
            liveLayer.path = nil
            return
        }
        switch tool {
        case .ink(let inkTool):
            guard !livePoints.isEmpty else { return }
            let points = livePoints
            livePoints = []
            updateLiveStroke(predicted: [], keeping: points)
            onStroke?(inkTool, inkColor, points)
        case .eraser:
            if !pendingErased.isEmpty {
                onErase?(pendingErased)
            }
        case .text:
            let point = camera.toPage(location)
            if let movingText {
                if hasMoved {
                    let box = TextBox(x: movingText.origin.x + Double(textOffset.dx), y: movingText.origin.y + Double(textOffset.dy), width: movingText.origin.width)
                    onTextMove?(movingText.id, box)
                } else {
                    self.movingText = nil
                    onTextTap?(point, movingText.id)
                }
            } else {
                onTextTap?(point, nil)
            }
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        cancelHoldTimer()
        if isHolding {
            onHoldEnd?(CGPoint(x: -1, y: -1))
        }
        livePoints = []
        liveLayer.path = nil
        clearPendingFeedback()
        resetGesture()
        setNeedsDisplay()
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }

    @objc private func handlePinch(_ pinch: UIPinchGestureRecognizer) {
        guard pinch.state == .began || pinch.state == .changed else { return }
        camera = camera.zoomed(by: pinch.scale, around: pinch.location(in: self))
        pinch.scale = 1
        cameraChanged()
    }

    @objc private func handlePan(_ pan: UIPanGestureRecognizer) {
        guard pan.state == .began || pan.state == .changed else { return }
        let translation = pan.translation(in: self)
        camera.offset.x += translation.x
        camera.offset.y += translation.y
        pan.setTranslation(.zero, in: self)
        cameraChanged()
    }

    private func cameraChanged() {
        if !livePoints.isEmpty {
            updateLiveStroke(predicted: [])
        } else {
            liveLayer.path = nil
        }
        setNeedsDisplay()
        onCameraChange?(camera)
    }

    private func updateLiveStroke(predicted: [Point], keeping kept: [Point]? = nil) {
        guard case .ink(let inkTool) = tool else { return }
        let style = InkStyle.tokens(for: inkTool)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        liveLayer.lineWidth = CGFloat(style.width) * camera.scale
        liveLayer.strokeColor = UIColor(hex: inkColor).withAlphaComponent(CGFloat(style.opacity)).cgColor
        liveLayer.path = StrokePathCache.makePath((kept ?? livePoints) + predicted, transform: camera.toScreen)
        CATransaction.commit()
    }

    private func erase(at location: CGPoint) {
        guard let page else { return }
        let point = camera.toPage(location)
        let reach = max(Tokens.shared.tools.eraser.radius, Double(Self.minimumEraserReach / camera.scale))
        var didErase = false
        for element in page.liveElements where element.type == .stroke && !pendingErased.contains(element.id) {
            if StrokeGeometry.isHit(element, by: point, radius: reach) {
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
        livePoints = []
        liveLayer.path = nil
        clearPendingFeedback()
        setNeedsDisplay()
        Haptics.hold()
        onHold?(convert(gestureStart, to: nil))
    }

    private func clearPendingFeedback() {
        pendingErased = []
        movingText = nil
        textOffset = .zero
        if livePoints.isEmpty {
            liveLayer.path = nil
        }
    }

    private func resetGesture() {
        activeTouch = nil
        isHolding = false
        isPanningWithFinger = false
        hasMoved = false
    }
}
