import { axisSnapped, clampBox, clipToPaper, cutStroke, isInsidePaper, isStrokeSwept, liveElements, paperHeight, paperWidth, smoothStroke, straightened } from "./model.js"
import { Camera, StrokePathCache, clipToPaper as clipContextToPaper, drawPage, strokePath, textRect } from "./renderer.js"
import { subscribeImports } from "./imports.js"
import { duration, tween } from "./motion.js"
import { inkOnPaper, tokens, withAlpha } from "./tokens.js"

const fitMargin = 24
const holdTolerance = 8
const minimumEraserReach = 6
const wheelZoomPerPixel = 0.0025
const multiTouchTapMilliseconds = 320
const multiTouchDoubleTapMilliseconds = 420
const multiTouchTapTolerance = 14
const minimumSampleSpacingPoints = 0.25
const minimumStraightLengthPoints = 24
const boundsCache = new WeakMap()

function pointsBounds(points) {
    const cached = boundsCache.get(points)
    if (cached) {
        return cached
    }
    let minimumX = Infinity
    let minimumY = Infinity
    let maximumX = -Infinity
    let maximumY = -Infinity
    for (const [x, y] of points) {
        minimumX = Math.min(minimumX, x)
        minimumY = Math.min(minimumY, y)
        maximumX = Math.max(maximumX, x)
        maximumY = Math.max(maximumY, y)
    }
    const bounds = { minimumX, minimumY, maximumX, maximumY }
    boundsCache.set(points, bounds)
    return bounds
}

function isNearSweep(points, sweepStart, sweepEnd, reach) {
    const bounds = pointsBounds(points)
    return Math.min(sweepStart[0], sweepEnd[0]) - reach <= bounds.maximumX
        && Math.max(sweepStart[0], sweepEnd[0]) + reach >= bounds.minimumX
        && Math.min(sweepStart[1], sweepEnd[1]) - reach <= bounds.maximumY
        && Math.max(sweepStart[1], sweepEnd[1]) + reach >= bounds.minimumY
}

export class InkCanvas {
    constructor(callbacks) {
        this.callbacks = callbacks
        this.element = document.createElement("div")
        this.element.className = "ink-canvas"
        this.pageCanvas = document.createElement("canvas")
        this.liveCanvas = document.createElement("canvas")
        this.element.append(this.pageCanvas, this.liveCanvas)
        this.page = null
        this.tool = { kind: "ink", tool: "pen", color: "#1A1A1A", width: tokens.tools.pen.width }
        this.paperStyle = tokens.page.default_style
        this.areaErase = new Map()
        this.hoverLocation = null
        this.multiTouch = null
        this.lastMultiTouchTap = null
        this.isReadOnly = false
        this.showsGuides = true
        this.hiddenElementIds = new Set()
        this.camera = new Camera()
        this.cache = new StrokePathCache()
        this.width = 0
        this.height = 0
        this.pixelRatio = window.devicePixelRatio || 1
        this.hasFitted = false
        this.topInset = 0
        this.activePointer = null
        this.touchPointers = new Map()
        this.stroke = null
        this.liveRequest = null
        this.lastErasePoint = null
        this.pendingErased = []
        this.movingText = null
        this.textOffset = [0, 0]
        this.hasMoved = false
        this.isHolding = false
        this.isPanning = false
        this.hasSeenPen = false
        this.holdTimer = null
        this.drawRequest = null
        this.isSpaceHeld = false

        new ResizeObserver(() => this.layout()).observe(this.element)
        this.element.addEventListener("pointerdown", (event) => this.pointerDown(event))
        this.element.addEventListener("pointermove", (event) => this.pointerMove(event))
        this.element.addEventListener("pointerup", (event) => this.pointerUp(event))
        this.element.addEventListener("pointercancel", (event) => this.pointerCancel(event))
        this.element.addEventListener("wheel", (event) => this.wheel(event), { passive: false })
        this.element.addEventListener("contextmenu", (event) => event.preventDefault())
        this.element.addEventListener("pointerleave", () => {
            this.hoverLocation = null
            this.drawLive()
        })
        this.keyDown = (event) => {
            if (event.code === "Space" && !event.repeat && document.activeElement?.tagName !== "TEXTAREA" && document.activeElement?.tagName !== "INPUT") {
                this.isSpaceHeld = true
                this.element.classList.add("is-grabbing")
            }
        }
        this.keyUp = (event) => {
            if (event.code === "Space") {
                this.isSpaceHeld = false
                this.element.classList.remove("is-grabbing")
            }
        }
        window.addEventListener("keydown", this.keyDown)
        window.addEventListener("keyup", this.keyUp)
        this.unsubscribeImports = subscribeImports(() => this.requestDraw())
    }

    destroy() {
        this.unsubscribeImports()
        window.removeEventListener("keydown", this.keyDown)
        window.removeEventListener("keyup", this.keyUp)
        clearTimeout(this.holdTimer)
        this.endStroke()
    }

    configure({ page, tool, paperStyle, showsGuides, showsDividers, hiddenElementIds, isReadOnly }) {
        const isNewPage = this.page?.id !== page.id
        const needsDraw = this.page !== page || this.showsGuides !== showsGuides || this.showsDividers !== showsDividers || this.paperStyle !== paperStyle || !sameSet(this.hiddenElementIds, hiddenElementIds)
        this.page = page
        this.tool = tool
        this.paperStyle = paperStyle
        this.showsGuides = showsGuides
        this.showsDividers = showsDividers
        this.hiddenElementIds = hiddenElementIds
        this.isReadOnly = isReadOnly
        if (isNewPage) {
            this.hasFitted = false
            this.layout()
        }
        if (needsDraw) {
            this.clearPendingFeedback()
            this.requestDraw()
        }
    }

    fit() {
        if (!this.page || this.width === 0) {
            return
        }
        this.camera = Camera.fitting(this.page.extent, this.width, this.height, fitMargin, this.topInset)
        this.hasFitted = true
        this.cameraChanged()
    }

    setInsets({ top }) {
        if (top === this.topInset) {
            return
        }
        const wasFitted = this.hasFitted && this.page && this.width > 0 && this.isCameraFitted()
        this.topInset = top
        if (wasFitted || !this.hasFitted) {
            this.hasFitted = false
            this.layout()
        }
    }

    isCameraFitted() {
        const fitted = Camera.fitting(this.page.extent, this.width, this.height, fitMargin, this.topInset)
        return Math.abs(fitted.scale - this.camera.scale) < 1e-6 && Math.abs(fitted.offsetX - this.camera.offsetX) < 0.5 && Math.abs(fitted.offsetY - this.camera.offsetY) < 0.5
    }

    layout() {
        const width = this.element.clientWidth
        const height = this.element.clientHeight
        const pixelRatio = window.devicePixelRatio || 1
        if (width === 0 || height === 0) {
            return
        }
        if (width !== this.width || height !== this.height || pixelRatio !== this.pixelRatio) {
            this.width = width
            this.height = height
            this.pixelRatio = pixelRatio
            for (const canvas of [this.pageCanvas, this.liveCanvas]) {
                canvas.width = Math.round(width * pixelRatio)
                canvas.height = Math.round(height * pixelRatio)
            }
            this.requestDraw()
            this.drawLive()
        }
        if (!this.hasFitted) {
            this.fit()
        }
    }

    requestDraw() {
        if (this.drawRequest) {
            return
        }
        this.drawRequest = requestAnimationFrame(() => {
            this.drawRequest = null
            this.draw()
        })
    }

    draw() {
        if (!this.page || this.width === 0) {
            return
        }
        const textOffsets = new Map()
        if (this.movingText) {
            textOffsets.set(this.movingText.id, this.textOffset)
        }
        let page = this.page
        if (this.areaErase.size) {
            const pieces = []
            for (const [elementId, entry] of this.areaErase) {
                entry.pieces.forEach((points, index) => pieces.push({ ...entry.element, id: `${elementId}-piece-${index}`, updated: `${entry.element.updated}-${entry.revision}`, points }))
            }
            page = { ...page, elements: [...page.elements.filter((element) => !this.areaErase.has(element.id)), ...pieces] }
        }
        drawPage(this.pageCanvas.getContext("2d"), page, this.camera, {
            width: this.width,
            height: this.height,
            pixelRatio: this.pixelRatio,
            showsGuides: this.showsGuides,
            showsDividers: this.showsDividers,
            paperStyle: this.paperStyle,
            hiddenElementIds: new Set([...this.hiddenElementIds, ...this.pendingErased]),
            textOffsets,
            cache: this.cache,
        })
        if (!this.stroke) {
            this.drawLive([])
        }
    }

    eraserReach() {
        return Math.max(this.tool.radius ?? tokens.tools.eraser.radius, minimumEraserReach / this.camera.scale)
    }

    strokePoints(predicted = []) {
        const stroke = this.stroke
        if (!stroke) {
            return []
        }
        const smooth = smoothStroke([...stroke.raw, ...predicted], this.camera.scale)
        if (!stroke.straight) {
            return smooth
        }
        return straightened(smooth, stroke.raw[0], axisSnapped(stroke.raw[0], stroke.straight.end), stroke.straight.share)
    }

    finalStrokePoints() {
        const stroke = this.stroke
        if (stroke.straight) {
            return smoothStroke([stroke.raw[0], axisSnapped(stroke.raw[0], stroke.straight.end)], this.camera.scale)
        }
        return smoothStroke(stroke.raw, this.camera.scale)
    }

    requestLive() {
        if (this.liveRequest) {
            return
        }
        this.liveRequest = requestAnimationFrame(() => {
            this.liveRequest = null
            this.drawLive(this.strokePoints(this.stroke?.predicted ?? []))
        })
    }

    beginStroke(location, point) {
        this.endStroke()
        this.stroke = { raw: [point], predicted: [], straight: null, still: null, stillTimer: null, snap: null, screenLength: 0, lastLocation: location }
        this.restartStill(location)
        this.drawLive([point])
    }

    extendStroke(location, point) {
        const stroke = this.stroke
        if (stroke.straight) {
            stroke.straight.end = point
            return
        }
        const travelled = Math.hypot(location[0] - stroke.lastLocation[0], location[1] - stroke.lastLocation[1])
        if (travelled < minimumSampleSpacingPoints) {
            return
        }
        stroke.screenLength += travelled
        stroke.lastLocation = location
        stroke.raw.push(point)
        if (Math.hypot(location[0] - stroke.still.location[0], location[1] - stroke.still.location[1]) > tokens.ink.straighten_tolerance_points) {
            this.restartStill(location)
        }
    }

    restartStill(location) {
        const stroke = this.stroke
        clearTimeout(stroke.stillTimer)
        stroke.still = { location }
        stroke.stillTimer = setTimeout(() => this.straightenStroke(), duration("stroke_straighten_hold"))
    }

    straightenStroke() {
        const stroke = this.stroke
        if (!stroke || stroke.straight || stroke.screenLength < minimumStraightLengthPoints) {
            return
        }
        stroke.straight = { end: stroke.raw[stroke.raw.length - 1], share: 0 }
        stroke.predicted = []
        stroke.snap = tween({
            milliseconds: duration("stroke_straighten_snap"),
            curveName: "power_two_out",
            onFrame: (share) => {
                if (this.stroke === stroke) {
                    stroke.straight.share = share
                    this.requestLive()
                }
            },
        })
    }

    endStroke() {
        if (!this.stroke) {
            return
        }
        clearTimeout(this.stroke.stillTimer)
        this.stroke.snap?.stop()
        this.stroke = null
    }

    drawLive(points = this.strokePoints()) {
        const context = this.liveCanvas.getContext("2d")
        context.setTransform(1, 0, 0, 1, 0, 0)
        context.clearRect(0, 0, this.liveCanvas.width, this.liveCanvas.height)
        context.setTransform(this.pixelRatio, 0, 0, this.pixelRatio, 0, 0)
        if (this.tool.kind === "eraser" && this.hoverLocation && !this.isPanning && !this.isHolding) {
            context.beginPath()
            context.arc(this.hoverLocation[0], this.hoverLocation[1], this.eraserReach() * this.camera.scale, 0, Math.PI * 2)
            context.fillStyle = withAlpha(tokens.semantic.destructive, 0.12)
            context.fill()
            context.lineWidth = 1.5
            context.strokeStyle = withAlpha(tokens.semantic.destructive, 0.9)
            context.stroke()
            return
        }
        if (!points.length || this.tool.kind !== "ink" || this.isPanning || this.isHolding) {
            return
        }
        const style = tokens.tools[this.tool.tool]
        context.save()
        context.translate(this.camera.offsetX, this.camera.offsetY)
        context.scale(this.camera.scale, this.camera.scale)
        clipContextToPaper(context, this.page.extent)
        context.setTransform(this.pixelRatio, 0, 0, this.pixelRatio, 0, 0)
        context.lineWidth = this.tool.width * this.camera.scale
        context.lineCap = "round"
        context.lineJoin = "round"
        context.strokeStyle = withAlpha(inkOnPaper(this.tool.color, this.paperStyle), style.opacity)
        context.stroke(strokePath(points, (point) => this.camera.toScreen(point)))
        context.restore()
    }

    constrainCamera() {
        if (!this.page || this.width === 0) {
            return
        }
        const extent = this.page.extent
        const top = this.topInset + fitMargin
        const availableWidth = Math.max(1, this.width - fitMargin * 2)
        const availableHeight = Math.max(1, this.height - top - fitMargin)
        const smallest = Math.min(availableWidth / paperWidth(extent), availableHeight / paperHeight(extent))
        if (this.camera.scale < smallest) {
            this.camera = this.camera.zoomed(smallest / this.camera.scale, this.width / 2, top + availableHeight / 2)
        }
        const axis = (offset, size, start, end) => (size <= end - start ? start + (end - start - size) / 2 : Math.min(start, Math.max(end - size, offset)))
        this.camera.offsetX = axis(this.camera.offsetX, paperWidth(extent) * this.camera.scale, fitMargin, this.width - fitMargin)
        this.camera.offsetY = axis(this.camera.offsetY, paperHeight(extent) * this.camera.scale, top, this.height - fitMargin)
    }

    cameraChanged() {
        this.constrainCamera()
        this.drawLive()
        this.requestDraw()
        this.callbacks.onCameraChange?.(this.camera)
    }

    localPoint(event) {
        const rect = this.element.getBoundingClientRect()
        return [event.clientX - rect.left, event.clientY - rect.top]
    }

    trackMultiTouchDown(event) {
        const location = [event.clientX, event.clientY]
        if (this.touchPointers.size === 0) {
            this.multiTouch = { started: performance.now(), count: 0, starts: new Map(), isSpoiled: false }
        }
        if (!this.multiTouch) {
            return
        }
        this.multiTouch.starts.set(event.pointerId, location)
        this.multiTouch.count = Math.max(this.multiTouch.count, this.touchPointers.size + 1)
    }

    trackMultiTouchMove(event) {
        const start = this.multiTouch?.starts.get(event.pointerId)
        if (start && Math.hypot(event.clientX - start[0], event.clientY - start[1]) > multiTouchTapTolerance) {
            this.multiTouch.isSpoiled = true
        }
    }

    trackMultiTouchUp() {
        const session = this.multiTouch
        if (!session || this.touchPointers.size > 0) {
            return
        }
        this.multiTouch = null
        const now = performance.now()
        if (session.isSpoiled || session.count < 2 || now - session.started > multiTouchTapMilliseconds) {
            this.lastMultiTouchTap = null
            return
        }
        const previous = this.lastMultiTouchTap
        if (previous && previous.count === session.count && now - previous.time <= multiTouchDoubleTapMilliseconds) {
            this.lastMultiTouchTap = null
            if (session.count === 2) {
                this.callbacks.onUndo?.()
            } else {
                this.callbacks.onRedo?.()
            }
            return
        }
        this.lastMultiTouchTap = { count: session.count, time: now }
    }

    pointerDown(event) {
        if (event.pointerType === "touch") {
            this.trackMultiTouchDown(event)
            this.touchPointers.set(event.pointerId, this.localPoint(event))
            if (this.touchPointers.size === 2) {
                this.cancelActiveGesture()
                this.pinchStart = this.pinchState()
                return
            }
            if (this.touchPointers.size > 2) {
                return
            }
        }
        if (this.activePointer !== null) {
            return
        }
        if (event.pointerType === "mouse" && event.button === 2) {
            this.callbacks.onHold?.(event.clientX, event.clientY, false)
            return
        }
        const location = this.localPoint(event)
        this.element.setPointerCapture(event.pointerId)
        this.activePointer = event.pointerId
        this.gestureStart = location
        this.lastPanLocation = location
        this.hasMoved = false
        this.isHolding = false
        this.callbacks.onInput?.()
        const isFinger = event.pointerType === "touch"
        if (event.pointerType === "pen") {
            this.hasSeenPen = true
        }
        if (event.pointerType === "mouse" && (event.button === 1 || this.isSpaceHeld)) {
            this.isPanning = true
            return
        }
        if (isFinger) {
            this.startHoldTimer(event.clientX, event.clientY)
            if (this.hasSeenPen) {
                this.isPanning = true
                return
            }
        }
        if (this.isReadOnly) {
            return
        }
        const point = this.camera.toPage(location[0], location[1])
        if (this.tool.kind === "ink") {
            if (!isInsidePaper(point, this.page.extent)) {
                this.isPanning = true
                return
            }
            this.beginStroke(location, point)
        } else if (this.tool.kind === "eraser") {
            this.hoverLocation = location
            this.lastErasePoint = point
            this.erase(point, point)
            this.drawLive()
        } else if (this.tool.kind === "text") {
            const element = this.textElement(point)
            if (element) {
                this.movingText = { id: element.id, origin: element.box, start: point, height: textRect(element).height }
            }
        }
    }

    pointerMove(event) {
        if (event.pointerType !== "touch") {
            this.hoverLocation = this.localPoint(event)
            if (this.tool.kind === "eraser" && this.activePointer === null) {
                this.drawLive()
            }
        }
        if (event.pointerType === "touch") {
            this.trackMultiTouchMove(event)
        }
        if (event.pointerType === "touch" && this.touchPointers.has(event.pointerId)) {
            this.touchPointers.set(event.pointerId, this.localPoint(event))
            if (this.touchPointers.size === 2 && this.pinchStart) {
                const state = this.pinchState()
                const zoomed = this.camera.zoomed(state.distance / this.pinchStart.distance, state.center[0], state.center[1])
                zoomed.offsetX += state.center[0] - this.pinchStart.center[0]
                zoomed.offsetY += state.center[1] - this.pinchStart.center[1]
                this.camera = zoomed
                this.pinchStart = state
                this.cameraChanged()
                return
            }
        }
        if (event.pointerId !== this.activePointer) {
            return
        }
        const location = this.localPoint(event)
        if (Math.hypot(location[0] - this.gestureStart[0], location[1] - this.gestureStart[1]) > holdTolerance) {
            this.hasMoved = true
            this.cancelHoldTimer()
        }
        if (this.isHolding) {
            this.callbacks.onHoldMove?.(event.clientX, event.clientY)
            return
        }
        if (this.isPanning) {
            this.camera.offsetX += location[0] - this.lastPanLocation[0]
            this.camera.offsetY += location[1] - this.lastPanLocation[1]
            this.lastPanLocation = location
            this.cameraChanged()
            return
        }
        if (this.isReadOnly) {
            return
        }
        const samples = event.getCoalescedEvents ? event.getCoalescedEvents() : [event]
        if (this.tool.kind === "ink" && this.stroke) {
            for (const sample of samples.length ? samples : [event]) {
                const sampleLocation = this.localPoint(sample)
                this.extendStroke(sampleLocation, this.camera.toPage(sampleLocation[0], sampleLocation[1]))
            }
            this.stroke.predicted = this.stroke.straight ? [] : (event.getPredictedEvents ? event.getPredictedEvents() : []).slice(0, 1).map((sample) => {
                const sampleLocation = this.localPoint(sample)
                return this.camera.toPage(sampleLocation[0], sampleLocation[1])
            })
            this.requestLive()
        } else if (this.tool.kind === "eraser" && this.lastErasePoint) {
            for (const sample of samples.length ? samples : [event]) {
                const sampleLocation = this.localPoint(sample)
                const point = this.camera.toPage(sampleLocation[0], sampleLocation[1])
                this.erase(this.lastErasePoint, point)
                this.lastErasePoint = point
            }
            this.hoverLocation = location
            this.drawLive()
        } else if (this.tool.kind === "text" && this.movingText && this.hasMoved) {
            const point = this.camera.toPage(location[0], location[1])
            const moving = this.movingText
            const box = clampBox({ ...moving.origin, x: moving.origin.x + point[0] - moving.start[0], y: moving.origin.y + point[1] - moving.start[1] }, this.page.extent, moving.height)
            this.textOffset = [box.x - moving.origin.x, box.y - moving.origin.y]
            this.requestDraw()
        }
    }

    pointerUp(event) {
        if (event.pointerType === "touch") {
            this.touchPointers.delete(event.pointerId)
            if (this.touchPointers.size < 2) {
                this.pinchStart = null
            }
            this.trackMultiTouchUp()
        }
        if (event.pointerId !== this.activePointer) {
            return
        }
        this.cancelHoldTimer()
        const location = this.localPoint(event)
        const wasHolding = this.isHolding
        const wasPanning = this.isPanning
        this.resetGesture()
        if (wasHolding) {
            this.callbacks.onHoldEnd?.(event.clientX, event.clientY)
            return
        }
        if (wasPanning || this.isReadOnly) {
            this.endStroke()
            this.drawLive()
            return
        }
        if (this.tool.kind === "ink") {
            if (!this.stroke) {
                return
            }
            const sampleLocation = this.localPoint(event)
            this.extendStroke(sampleLocation, this.camera.toPage(sampleLocation[0], sampleLocation[1]))
            const points = this.finalStrokePoints()
            this.endStroke()
            this.drawLive(points)
            this.callbacks.onStroke?.(this.tool.tool, this.tool.color, clipToPaper(points, this.page.extent), this.tool.width)
        } else if (this.tool.kind === "eraser") {
            this.lastErasePoint = null
            if (event.pointerType === "touch") {
                this.hoverLocation = null
                this.drawLive()
            }
            if (this.pendingErased.length) {
                this.callbacks.onErase?.([...this.pendingErased])
            }
            if (this.areaErase.size) {
                const replacements = [...this.areaErase.entries()].map(([elementId, entry]) => ({ elementId, pieces: entry.pieces }))
                this.areaErase = new Map()
                this.callbacks.onEraseArea?.(replacements)
            }
        } else if (this.tool.kind === "text") {
            const point = this.camera.toPage(location[0], location[1])
            const moving = this.movingText
            if (moving) {
                if (this.textOffsetMoved) {
                    this.callbacks.onTextMove?.(moving.id, this.movedTextBox())
                } else {
                    this.movingText = null
                    this.callbacks.onTextTap?.(point, moving.id)
                }
            } else if (isInsidePaper(point, this.page.extent)) {
                this.callbacks.onTextTap?.(point, null)
            }
        }
    }

    pointerCancel(event) {
        this.touchPointers.delete(event.pointerId)
        if (this.touchPointers.size === 0) {
            this.multiTouch = null
        }
        if (event.pointerId !== this.activePointer) {
            return
        }
        this.cancelActiveGesture()
    }

    cancelActiveGesture() {
        this.cancelHoldTimer()
        if (this.isHolding) {
            this.callbacks.onHoldEnd?.(-1, -1)
        }
        this.endStroke()
        this.lastErasePoint = null
        this.drawLive()
        this.clearPendingFeedback()
        this.resetGesture()
        this.requestDraw()
    }

    pinchState() {
        const [first, second] = [...this.touchPointers.values()]
        return { distance: Math.max(1, Math.hypot(first[0] - second[0], first[1] - second[1])), center: [(first[0] + second[0]) / 2, (first[1] + second[1]) / 2] }
    }

    wheel(event) {
        event.preventDefault()
        const location = this.localPoint(event)
        if (event.ctrlKey || event.metaKey) {
            this.camera = this.camera.zoomed(Math.exp(-event.deltaY * wheelZoomPerPixel * (event.deltaMode === 1 ? 16 : 1)), location[0], location[1])
        } else {
            const lineHeight = event.deltaMode === 1 ? 16 : 1
            const horizontal = event.shiftKey && event.deltaX === 0 ? event.deltaY : event.deltaX
            const vertical = event.shiftKey && event.deltaX === 0 ? 0 : event.deltaY
            this.camera.offsetX -= horizontal * lineHeight
            this.camera.offsetY -= vertical * lineHeight
        }
        this.cameraChanged()
    }

    erase(sweepStart, sweepEnd) {
        if (!this.page) {
            return
        }
        const reach = this.eraserReach()
        let didErase = false
        for (const element of liveElements(this.page)) {
            if (element.type !== "stroke" || !element.points?.length) {
                continue
            }
            const strokeReach = reach + (element.width ?? 0) / 2
            if (this.tool.mode === "area") {
                const entry = this.areaErase.get(element.id)
                const pieces = entry ? entry.pieces : [element.points]
                let isTouched = false
                const nextPieces = []
                for (const points of pieces) {
                    const cut = isNearSweep(points, sweepStart, sweepEnd, strokeReach) ? cutStroke(points, sweepStart, sweepEnd, strokeReach) : null
                    if (cut) {
                        isTouched = true
                        nextPieces.push(...cut)
                    } else {
                        nextPieces.push(points)
                    }
                }
                if (isTouched) {
                    this.areaErase.set(element.id, { element, pieces: nextPieces, revision: (entry?.revision ?? 0) + 1 })
                    didErase = true
                }
            } else if (!this.pendingErased.includes(element.id) && isNearSweep(element.points, sweepStart, sweepEnd, strokeReach) && isStrokeSwept(element, sweepStart, sweepEnd, reach)) {
                this.pendingErased.push(element.id)
                didErase = true
            }
        }
        if (didErase) {
            this.requestDraw()
        }
    }

    textElement(point) {
        const elements = liveElements(this.page).reverse()
        return elements.find((element) => {
            const rect = textRect(element)
            return rect && point[0] >= rect.x - 2 && point[0] <= rect.x + rect.width + 2 && point[1] >= rect.y - 2 && point[1] <= rect.y + rect.height + 2
        })
    }

    startHoldTimer(clientX, clientY) {
        this.cancelHoldTimer()
        this.holdTimer = setTimeout(() => this.beginHold(clientX, clientY), duration("menu_hold"))
    }

    cancelHoldTimer() {
        clearTimeout(this.holdTimer)
        this.holdTimer = null
    }

    beginHold(clientX, clientY) {
        if (this.activePointer === null || this.hasMoved) {
            return
        }
        this.isHolding = true
        this.isPanning = false
        this.endStroke()
        this.drawLive()
        this.clearPendingFeedback()
        this.requestDraw()
        this.callbacks.onHold?.(clientX, clientY, true)
    }

    clearPendingFeedback() {
        this.pendingErased = []
        this.areaErase = new Map()
        this.movingText = null
        this.textOffset = [0, 0]
    }

    movedTextBox() {
        const origin = this.movingText.origin
        return { x: origin.x + this.textOffset[0], y: origin.y + this.textOffset[1], width: origin.width }
    }

    get textOffsetMoved() {
        return this.textOffset[0] !== 0 || this.textOffset[1] !== 0
    }

    resetGesture() {
        this.activePointer = null
        this.isHolding = false
        this.isPanning = false
        this.hasMoved = false
    }
}

function sameSet(first, second) {
    if (first.size !== second.size) {
        return false
    }
    for (const value of first) {
        if (!second.has(value)) {
            return false
        }
    }
    return true
}
