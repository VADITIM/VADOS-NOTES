import {
    axisSnapped,
    clampBox,
    clipToPaper,
    cutStroke,
    isInsidePaper,
    isStrokeSwept,
    lassoTouchesArea,
    lassoTouchesLine,
    liveElements,
    paperHeight,
    paperWidth,
    pointsBounds,
    smoothStroke,
    straightened,
} from "./model.js"
import { duration } from "./motion.js"
import { Camera, StrokePathCache, drawPage, importRect, strokePath, textRect } from "./renderer.js"
import { subscribeImports } from "./imports.js"
import { inkOnPaper, tokens, withAlpha } from "./tokens.js"

const fitMargin = 24
const holdTolerance = 8
const minimumEraserReach = 6
const minimumSampleSpacing = 0.25
const minimumStraightLength = 24
const selectionPadding = 8
const lassoDash = [6, 5]
const selectionScaleRange = [0.1, 10]
const glideStopSpeed = 12
const glideSampleWindow = 80
const undoTapTravel = 10
const wheelZoomRate = 0.0025
const penEraserButtons = 32

export class InkCanvas {
    constructor(callbacks) {
        this.callbacks = callbacks
        this.element = document.createElement("div")
        this.element.className = "ink-canvas"
        this.paperCanvas = document.createElement("canvas")
        this.overlayCanvas = document.createElement("canvas")
        this.element.append(this.paperCanvas, this.overlayCanvas)
        this.paperContext = this.paperCanvas.getContext("2d")
        this.overlayContext = this.overlayCanvas.getContext("2d")
        this.page = null
        this.tool = { kind: "ink", tool: "pen" }
        this.inkColor = "#1A1A1A"
        this.inkWidth = 0.5
        this.eraserRadius = 2
        this.paperStyle = "dark"
        this.showsGuides = true
        this.showsDividers = true
        this.showsBackdrop = false
        this.inkSmoothing = tokens.ink.smoothing_points
        this.hiddenElementIds = new Set()
        this.isReadOnly = false
        this.topInset = 0
        this.camera = new Camera()
        this.cache = new StrokePathCache()
        this.width = 0
        this.height = 0
        this.hasFitted = false
        this.fittedSize = [0, 0]
        this.touches = new Map()
        this.active = null
        this.stroke = null
        this.snap = null
        this.glide = null
        this.panSamples = []
        this.holdTimer = null
        this.isHolding = false
        this.isPanning = false
        this.hasMoved = false
        this.gestureStart = [0, 0]
        this.lastPan = [0, 0]
        this.lastErasePoint = null
        this.pendingErased = []
        this.areaErase = new Map()
        this.pressedText = null
        this.textHoldTimer = null
        this.isTextLifted = false
        this.textOffset = [0, 0]
        this.lassoPoints = []
        this.selectedIds = []
        this.selectionBounds = null
        this.selectionStart = null
        this.selectionOffset = [0, 0]
        this.isSelectionTouchInside = false
        this.selectionScaleAnchor = null
        this.selectionScale = 1
        this.multiTouch = null
        this.tapSequence = null
        this.isSpaceHeld = false
        this.eraserBorrowed = false
        this.frameRequest = null
        this.overlayRequest = null
        this.resizeObserver = new ResizeObserver(() => this.layout())
        this.resizeObserver.observe(this.element)
        this.unsubscribeImports = subscribeImports(() => this.requestDraw())
        this.bindInput()
    }

    destroy() {
        this.resizeObserver.disconnect()
        this.unsubscribeImports()
        this.stopGlide()
        clearTimeout(this.holdTimer)
        clearTimeout(this.textHoldTimer)
        window.removeEventListener("keydown", this.keyDown)
        window.removeEventListener("keyup", this.keyUp)
    }

    configure(options) {
        const previous = this.page
        const wasInset = this.topInset
        Object.assign(this, options)
        if (previous?.id !== this.page?.id) {
            this.hasFitted = false
            this.selectedIds = []
        }
        if (wasInset !== this.topInset && (!this.hasFitted || this.isCameraFitted(wasInset))) {
            this.hasFitted = false
        }
        this.element.classList.toggle("shows-backdrop", this.showsBackdrop)
        if (previous !== this.page) {
            this.clearPendingFeedback()
            this.refreshSelection()
        }
        this.layout()
        this.requestDraw()
    }

    layout() {
        const rect = this.element.getBoundingClientRect()
        const width = Math.round(rect.width)
        const height = Math.round(rect.height)
        if (width === 0 || height === 0) {
            return
        }
        const ratio = window.devicePixelRatio || 1
        if (width !== this.width || height !== this.height || this.paperCanvas.width !== Math.round(width * ratio)) {
            this.width = width
            this.height = height
            for (const canvas of [this.paperCanvas, this.overlayCanvas]) {
                canvas.width = Math.round(width * ratio)
                canvas.height = Math.round(height * ratio)
            }
        }
        if (!this.hasFitted || this.fittedSize[0] !== width || this.fittedSize[1] !== height) {
            this.fit()
        }
        this.requestDraw()
    }

    fit() {
        if (!this.page || this.width === 0) {
            return
        }
        this.camera = Camera.fitting(this.page.extent, this.width, this.height, fitMargin, this.topInset)
        this.hasFitted = true
        this.fittedSize = [this.width, this.height]
        this.cameraChanged()
    }

    isCameraFitted(inset) {
        if (!this.page || this.width === 0) {
            return false
        }
        const fitted = Camera.fitting(this.page.extent, this.width, this.height, fitMargin, inset)
        return Math.abs(fitted.scale - this.camera.scale) < 1e-6 && Math.abs(fitted.offsetX - this.camera.offsetX) < 0.5 && Math.abs(fitted.offsetY - this.camera.offsetY) < 0.5
    }

    cameraChanged() {
        if (this.page) {
            this.camera = this.camera.constrained(this.page.extent, this.width, this.height, fitMargin, this.topInset)
        }
        this.requestDraw()
        this.callbacks.onCameraChange?.(this.camera)
    }

    requestDraw() {
        if (this.frameRequest) {
            return
        }
        this.frameRequest = requestAnimationFrame(() => {
            this.frameRequest = null
            this.draw()
            this.drawOverlay()
        })
    }

    requestOverlay() {
        if (this.overlayRequest || this.frameRequest) {
            return
        }
        this.overlayRequest = requestAnimationFrame(() => {
            this.overlayRequest = null
            this.drawOverlay()
        })
    }

    displayPage() {
        if (!this.page || this.areaErase.size === 0) {
            return this.page
        }
        const elements = this.page.elements.filter((element) => !this.areaErase.has(element.id))
        for (const [elementId, entry] of this.areaErase) {
            entry.pieces.forEach((points, index) => {
                elements.push({ ...entry.element, id: `${elementId}-piece-${index}-${entry.revision}`, points, updated: `${entry.element.updated}#${entry.revision}` })
            })
        }
        return { ...this.page, elements }
    }

    draw() {
        if (!this.page || this.width === 0) {
            return
        }
        const elementOffsets = new Map()
        if (this.pressedText && this.isTextLifted) {
            elementOffsets.set(this.pressedText.id, this.textOffset)
        }
        if (this.selectionOffset[0] !== 0 || this.selectionOffset[1] !== 0) {
            for (const id of this.selectedIds) {
                elementOffsets.set(id, this.selectionOffset)
            }
        }
        const elementScale = this.selectionScaleAnchor ? { ids: new Set(this.selectedIds), anchor: this.selectionScaleAnchor, factor: this.selectionScale } : null
        drawPage(this.paperContext, this.displayPage(), this.camera, {
            width: this.width,
            height: this.height,
            pixelRatio: window.devicePixelRatio || 1,
            showsGuides: this.showsGuides,
            showsDividers: this.showsDividers,
            paperStyle: this.paperStyle,
            hiddenElementIds: new Set([...this.hiddenElementIds, ...this.pendingErased]),
            elementOffsets,
            elementScale,
            fillsOutside: !this.showsBackdrop,
            cache: this.cache,
        })
    }

    drawOverlay() {
        const context = this.overlayContext
        const ratio = window.devicePixelRatio || 1
        context.setTransform(ratio, 0, 0, ratio, 0, 0)
        context.clearRect(0, 0, this.width, this.height)
        if (!this.page) {
            return
        }
        if (this.stroke && this.tool.kind === "ink") {
            const points = this.liveStrokePoints()
            const style = tokens.tools[this.tool.tool]
            context.save()
            context.beginPath()
            context.roundRect(this.camera.offsetX, this.camera.offsetY, paperWidth(this.page.extent) * this.camera.scale, paperHeight(this.page.extent) * this.camera.scale, tokens.page.corner_radius * this.camera.scale)
            context.clip()
            context.lineWidth = this.inkWidth * this.camera.scale
            context.lineCap = "round"
            context.lineJoin = "round"
            context.strokeStyle = withAlpha(inkOnPaper(this.inkColor, this.paperStyle), style.opacity)
            context.stroke(strokePath(points, (point) => this.camera.toScreen(point)))
            context.restore()
        }
        if (this.eraserAt) {
            const radius = this.eraserReach() * this.camera.scale
            context.beginPath()
            context.arc(this.eraserAt[0], this.eraserAt[1], radius, 0, Math.PI * 2)
            context.fillStyle = withAlpha(tokens.semantic.destructive, 0.12)
            context.fill()
            context.lineWidth = 1.5
            context.strokeStyle = withAlpha(tokens.semantic.destructive, 0.9)
            context.stroke()
        }
        if (this.lassoPoints.length >= 2) {
            context.beginPath()
            this.lassoPoints.forEach((point, index) => {
                const [x, y] = this.camera.toScreen(point)
                if (index === 0) {
                    context.moveTo(x, y)
                } else {
                    context.lineTo(x, y)
                }
            })
            context.closePath()
            context.fillStyle = withAlpha(tokens.palette.accent, 0.08)
            context.fill()
            context.setLineDash(lassoDash)
            context.lineWidth = 1.5
            context.strokeStyle = tokens.palette.accent
            context.stroke()
            context.setLineDash([])
        }
        const selection = this.selectionScreenRect()
        if (selection) {
            context.beginPath()
            context.roundRect(selection.x, selection.y, selection.width, selection.height, selectionPadding)
            context.fillStyle = withAlpha(tokens.palette.accent, 0.06)
            context.fill()
            context.setLineDash(lassoDash)
            context.lineWidth = 1.5
            context.strokeStyle = tokens.palette.accent
            context.stroke()
            context.setLineDash([])
        }
    }

    localPoint(event) {
        const rect = this.element.getBoundingClientRect()
        return [event.clientX - rect.left, event.clientY - rect.top]
    }

    bindInput() {
        const element = this.element
        element.addEventListener("pointerdown", (event) => this.pointerDown(event))
        element.addEventListener("pointermove", (event) => this.pointerMove(event))
        element.addEventListener("pointerup", (event) => this.pointerUp(event, false))
        element.addEventListener("pointercancel", (event) => this.pointerUp(event, true))
        element.addEventListener("lostpointercapture", (event) => {
            if (this.touches.has(event.pointerId) || this.active?.pointerId === event.pointerId) {
                this.pointerUp(event, true)
            }
        })
        element.addEventListener("contextmenu", (event) => {
            event.preventDefault()
            if (event.pointerType === "touch" || this.active) {
                return
            }
            this.callbacks.onInput?.()
            this.callbacks.onHold?.([event.clientX, event.clientY], true)
        })
        element.addEventListener("wheel", (event) => this.wheel(event), { passive: false })
        this.keyDown = (event) => {
            if (event.code === "Space" && !event.repeat && !isTyping(event)) {
                this.isSpaceHeld = true
                element.classList.add("is-grabbing")
            }
        }
        this.keyUp = (event) => {
            if (event.code === "Space") {
                this.isSpaceHeld = false
                element.classList.remove("is-grabbing")
            }
        }
        window.addEventListener("keydown", this.keyDown)
        window.addEventListener("keyup", this.keyUp)
    }

    wheel(event) {
        event.preventDefault()
        this.stopGlide()
        this.callbacks.onInput?.()
        if (event.ctrlKey) {
            const [x, y] = this.localPoint(event)
            const smallest = this.page ? Camera.smallestScale(this.page.extent, this.width, this.height, fitMargin, this.topInset) : 0
            const factor = Math.max(Math.exp(-event.deltaY * wheelZoomRate * (event.deltaMode === 1 ? 16 : 1)), smallest / this.camera.scale)
            this.camera = this.camera.zoomed(factor, x, y)
        } else {
            const unit = event.deltaMode === 1 ? 16 : 1
            this.camera.offsetX -= (event.shiftKey ? event.deltaY : event.deltaX) * unit
            this.camera.offsetY -= (event.shiftKey ? 0 : event.deltaY) * unit
        }
        this.cameraChanged()
    }

    pointerDown(event) {
        this.stopGlide()
        if (event.pointerType === "touch") {
            this.touches.set(event.pointerId, { start: this.localPoint(event), location: this.localPoint(event) })
            this.trackTap(event)
            if (this.touches.size >= 2) {
                this.beginMultiTouch()
                this.element.setPointerCapture(event.pointerId)
                return
            }
        } else if (this.active) {
            return
        }
        if (this.active || !this.page) {
            return
        }
        if (event.pointerType === "mouse" && event.button !== 0 && event.button !== 1) {
            return
        }
        this.element.setPointerCapture(event.pointerId)
        this.clearPendingFeedback()
        const isFinger = event.pointerType === "touch"
        const isPanButton = event.pointerType === "mouse" && (event.button === 1 || this.isSpaceHeld)
        const isEraserEnd = event.pointerType === "pen" && (event.buttons & penEraserButtons) !== 0
        this.active = { pointerId: event.pointerId, isFinger, isEraserEnd, type: event.pointerType }
        this.hasMoved = false
        this.isHolding = false
        this.gestureStart = this.localPoint(event)
        this.lastPan = this.gestureStart
        this.panSamples = [{ location: this.gestureStart, time: event.timeStamp }]
        this.callbacks.onInput?.()
        const point = this.camera.toPage(...this.gestureStart)
        this.callbacks.onSelectionMenu?.(null)
        if (isPanButton) {
            this.isPanning = true
            return
        }
        const selection = this.selectionScreenRect()
        const isInsideSelection = Boolean(selection && containsPoint(selection, this.gestureStart))
        const tool = isEraserEnd ? { kind: "eraser", mode: this.tool.kind === "eraser" ? this.tool.mode : "stroke" } : this.tool
        this.active.tool = tool
        if (!this.isReadOnly && this.selectedIds.length && (isFinger || (isInsideSelection && tool.kind === "lasso"))) {
            this.selectionStart = point
            this.isSelectionTouchInside = isInsideSelection
            return
        }
        if (tool.kind === "text" && !this.isReadOnly) {
            const element = this.textElementAt(point)
            const rect = element ? textRect(element) : null
            if (element && rect) {
                this.pressedText = { id: element.id, origin: element.box, start: point, height: rect.height }
                this.startTextHoldTimer()
                return
            }
        }
        if (isFinger) {
            this.startHoldTimer()
        }
        if (this.isReadOnly) {
            this.isPanning = isFinger
            return
        }
        switch (tool.kind) {
        case "ink":
            if (isFinger || !isInsidePaper(point, this.page.extent)) {
                this.isPanning = true
                return
            }
            this.beginStroke(this.gestureStart, point)
            break
        case "eraser":
            if (isFinger) {
                this.isPanning = true
                return
            }
            this.lastErasePoint = point
            this.erase(point, point, tool.mode)
            this.eraserAt = this.gestureStart
            this.requestOverlay()
            break
        case "text":
            this.isPanning = isFinger
            break
        case "lasso":
            if (isFinger) {
                this.isPanning = true
                return
            }
            this.lassoPoints = [point]
            break
        }
    }

    pointerMove(event) {
        if (event.pointerType === "touch" && this.touches.has(event.pointerId)) {
            const entry = this.touches.get(event.pointerId)
            entry.location = this.localPoint(event)
            this.trackTapMove(event, entry)
            if (this.multiTouch) {
                this.moveMultiTouch()
                return
            }
        }
        if (!this.active || this.active.pointerId !== event.pointerId || !this.page) {
            return
        }
        const location = this.localPoint(event)
        if (!this.hasMoved && Math.hypot(location[0] - this.gestureStart[0], location[1] - this.gestureStart[1]) > holdTolerance) {
            this.hasMoved = true
            clearTimeout(this.holdTimer)
            if (this.pressedText && !this.isTextLifted) {
                clearTimeout(this.textHoldTimer)
                this.pressedText = null
                this.isPanning = this.active.isFinger
            }
        }
        if (this.isHolding) {
            this.callbacks.onHoldMove?.([event.clientX, event.clientY])
            return
        }
        if (this.isPanning) {
            this.camera.offsetX += location[0] - this.lastPan[0]
            this.camera.offsetY += location[1] - this.lastPan[1]
            this.lastPan = location
            this.recordPanSample(location, event.timeStamp)
            this.cameraChanged()
            return
        }
        if (this.isReadOnly) {
            return
        }
        if (this.selectionStart) {
            const point = this.camera.toPage(...location)
            this.selectionOffset = [point[0] - this.selectionStart[0], point[1] - this.selectionStart[1]]
            this.requestDraw()
            return
        }
        if (this.pressedText) {
            if (!this.isTextLifted) {
                return
            }
            const point = this.camera.toPage(...location)
            const origin = this.pressedText.origin
            const moved = { ...origin, x: origin.x + point[0] - this.pressedText.start[0], y: origin.y + point[1] - this.pressedText.start[1] }
            const box = clampBox(moved, this.page.extent, this.pressedText.height)
            this.textOffset = [box.x - origin.x, box.y - origin.y]
            this.requestDraw()
            return
        }
        const samples = event.getCoalescedEvents?.().length ? event.getCoalescedEvents() : [event]
        const tool = this.active.tool
        switch (tool.kind) {
        case "ink":
            if (!this.stroke) {
                return
            }
            for (const sample of samples) {
                const sampleLocation = this.localPoint(sample)
                this.extendStroke(sampleLocation, this.camera.toPage(...sampleLocation))
            }
            if (this.stroke && this.stroke.straightEnd === null) {
                const predicted = event.getPredictedEvents?.() ?? []
                this.stroke.predicted = predicted.slice(0, 1).map((sample) => this.camera.toPage(...this.localPoint(sample)))
            }
            this.requestOverlay()
            break
        case "eraser":
            for (const sample of samples) {
                const point = this.camera.toPage(...this.localPoint(sample))
                this.erase(this.lastErasePoint ?? point, point, tool.mode)
                this.lastErasePoint = point
            }
            this.eraserAt = location
            this.requestOverlay()
            break
        case "lasso":
            for (const sample of samples) {
                this.lassoPoints.push(this.camera.toPage(...this.localPoint(sample)))
            }
            this.requestOverlay()
            break
        default:
            break
        }
    }

    pointerUp(event, isCancelled) {
        if (event.pointerType === "touch" && this.touches.has(event.pointerId)) {
            this.touches.delete(event.pointerId)
            this.trackTapEnd(event)
            if (this.multiTouch) {
                if (this.touches.size < 2) {
                    this.endMultiTouch()
                } else {
                    this.beginMultiTouch()
                }
                return
            }
        }
        if (!this.active || this.active.pointerId !== event.pointerId || !this.page) {
            return
        }
        if (isCancelled) {
            this.cancelActiveGesture()
            return
        }
        clearTimeout(this.holdTimer)
        clearTimeout(this.textHoldTimer)
        const location = this.localPoint(event)
        const point = this.camera.toPage(...location)
        const wasHolding = this.isHolding
        const wasPanning = this.isPanning
        const wasMoved = this.hasMoved
        const active = this.active
        this.resetGesture()
        this.eraserAt = null
        this.requestOverlay()
        if (wasHolding) {
            this.callbacks.onHoldEnd?.([event.clientX, event.clientY])
            return
        }
        if (this.selectionStart) {
            this.finishSelectionMove(wasMoved)
            return
        }
        if (this.pressedText) {
            const pressed = this.pressedText
            if (this.isTextLifted) {
                if (this.textOffset[0] !== 0 || this.textOffset[1] !== 0) {
                    this.callbacks.onTextMove?.(pressed.id, { ...pressed.origin, x: pressed.origin.x + this.textOffset[0], y: pressed.origin.y + this.textOffset[1] })
                } else {
                    this.clearPendingFeedback()
                    this.requestDraw()
                }
            } else if (!wasMoved) {
                this.pressedText = null
                this.callbacks.onTextTap?.(point, pressed.id)
            }
            return
        }
        if (wasPanning) {
            this.endStroke()
            if (wasMoved) {
                this.recordPanSample(location, event.timeStamp)
                this.startGlide(this.panVelocity())
            }
            if (this.tool.kind === "text" && !wasMoved && !this.isReadOnly && isInsidePaper(point, this.page.extent)) {
                this.callbacks.onTextTap?.(point, null)
            }
            return
        }
        if (this.isReadOnly) {
            return
        }
        const tool = active.tool
        switch (tool.kind) {
        case "ink": {
            if (!this.stroke) {
                return
            }
            this.extendStroke(location, point)
            const points = this.finalStrokePoints()
            this.endStroke()
            this.callbacks.onStroke?.(tool.tool, this.inkColor, clipToPaper(points, this.page.extent), this.inkWidth)
            break
        }
        case "eraser":
            this.lastErasePoint = null
            if (this.pendingErased.length) {
                this.callbacks.onErase?.(this.pendingErased)
            }
            if (this.areaErase.size) {
                const replacements = [...this.areaErase.entries()].map(([elementId, entry]) => ({ elementId, pieces: entry.pieces }))
                this.areaErase = new Map()
                this.callbacks.onEraseArea?.(replacements)
            }
            if (active.isEraserEnd) {
                this.callbacks.onEraseLift?.()
            }
            break
        case "text":
            if (!wasMoved && isInsidePaper(point, this.page.extent)) {
                this.callbacks.onTextTap?.(point, null)
            }
            break
        case "lasso":
            this.finishLasso(wasMoved)
            break
        }
    }

    trackTap(event) {
        const now = event.timeStamp
        if (!this.tapSequence || this.touches.size === 1) {
            this.tapSequence = { start: now, maximumCount: 0, isFailed: false }
        }
        this.tapSequence.maximumCount = Math.max(this.tapSequence.maximumCount, this.touches.size)
    }

    trackTapMove(event, entry) {
        if (this.tapSequence && Math.hypot(entry.location[0] - entry.start[0], entry.location[1] - entry.start[1]) > undoTapTravel) {
            this.tapSequence.isFailed = true
        }
    }

    trackTapEnd(event) {
        const sequence = this.tapSequence
        if (!sequence) {
            return
        }
        if (event.timeStamp - sequence.start > duration("undo_tap")) {
            sequence.isFailed = true
        }
        if (this.touches.size > 0) {
            return
        }
        this.tapSequence = null
        if (sequence.isFailed) {
            return
        }
        if (sequence.maximumCount === 2) {
            this.callbacks.onUndo?.()
        } else if (sequence.maximumCount === 3) {
            this.callbacks.onRedo?.()
        }
    }

    multiTouchCentre() {
        const locations = [...this.touches.values()].slice(0, 2).map((entry) => entry.location)
        return {
            centre: [(locations[0][0] + locations[1][0]) / 2, (locations[0][1] + locations[1][1]) / 2],
            spread: Math.max(1, Math.hypot(locations[0][0] - locations[1][0], locations[0][1] - locations[1][1])),
        }
    }

    beginMultiTouch() {
        if (this.active) {
            this.cancelActiveGesture()
        }
        this.callbacks.onSelectionMenu?.(null)
        const { centre, spread } = this.multiTouchCentre()
        const isScalingSelection = !this.multiTouch && !this.isReadOnly && this.selectionBounds && containsPoint(this.selectionScreenRect(), centre)
        if (this.multiTouch?.isScalingSelection) {
            this.multiTouch = { ...this.multiTouch, centre, spread, startSpread: spread / this.selectionScale }
            return
        }
        if (isScalingSelection) {
            const bounds = this.selectionBounds
            this.selectionScaleAnchor = [bounds.x + bounds.width / 2, bounds.y + bounds.height / 2]
            this.selectionScale = 1
        }
        this.multiTouch = { centre, spread, startSpread: spread, isScalingSelection: Boolean(isScalingSelection), samples: [{ location: centre, time: performance.now() }] }
    }

    moveMultiTouch() {
        const touch = this.multiTouch
        if (this.touches.size < 2) {
            return
        }
        const { centre, spread } = this.multiTouchCentre()
        if (touch.isScalingSelection) {
            this.selectionScale = Math.min(selectionScaleRange[1], Math.max(selectionScaleRange[0], spread / touch.startSpread))
            this.requestDraw()
            return
        }
        this.camera.offsetX += centre[0] - touch.centre[0]
        this.camera.offsetY += centre[1] - touch.centre[1]
        const smallest = this.page ? Camera.smallestScale(this.page.extent, this.width, this.height, fitMargin, this.topInset) : 0
        const factor = Math.max(spread / touch.spread, smallest / this.camera.scale)
        if (Math.abs(factor - 1) > 1e-6) {
            this.camera = this.camera.zoomed(factor, centre[0], centre[1])
        }
        touch.centre = centre
        touch.spread = spread
        const now = performance.now()
        touch.samples.push({ location: centre, time: now })
        touch.samples = touch.samples.filter((sample) => now - sample.time <= glideSampleWindow)
        this.cameraChanged()
    }

    endMultiTouch() {
        const touch = this.multiTouch
        this.multiTouch = null
        if (touch.isScalingSelection) {
            this.finishSelectionScale()
            return
        }
        const first = touch.samples[0]
        const last = touch.samples[touch.samples.length - 1]
        if (first && last && last.time - first.time > 1) {
            const elapsed = (last.time - first.time) / 1000
            this.startGlide([(last.location[0] - first.location[0]) / elapsed, (last.location[1] - first.location[1]) / elapsed])
        }
    }

    finishSelectionScale() {
        const anchor = this.selectionScaleAnchor
        if (!anchor) {
            return
        }
        const factor = this.selectionScale
        this.selectionScaleAnchor = null
        this.selectionScale = 1
        if (Math.abs(factor - 1) > 0.001) {
            this.callbacks.onScaleElements?.(this.selectedIds, anchor, factor)
        }
        this.refreshSelection()
        this.requestDraw()
    }

    recordPanSample(location, time) {
        this.panSamples.push({ location, time })
        this.panSamples = this.panSamples.filter((sample) => time - sample.time <= glideSampleWindow)
    }

    panVelocity() {
        const first = this.panSamples[0]
        const last = this.panSamples[this.panSamples.length - 1]
        if (!first || !last || last.time - first.time <= 1) {
            return [0, 0]
        }
        const elapsed = (last.time - first.time) / 1000
        return [(last.location[0] - first.location[0]) / elapsed, (last.location[1] - first.location[1]) / elapsed]
    }

    startGlide(velocity) {
        this.stopGlide()
        if (Math.hypot(velocity[0], velocity[1]) <= glideStopSpeed) {
            return
        }
        const glide = { velocity: [...velocity], last: performance.now(), request: null }
        const step = (now) => {
            const elapsed = (now - glide.last) / 1000
            glide.last = now
            const before = [this.camera.offsetX, this.camera.offsetY]
            this.camera.offsetX += glide.velocity[0] * elapsed
            this.camera.offsetY += glide.velocity[1] * elapsed
            this.cameraChanged()
            const retained = Math.pow(tokens.motion.shares.pan_glide_decay, elapsed * 1000)
            glide.velocity[0] = Math.abs(this.camera.offsetX - before[0]) < 1e-6 ? 0 : glide.velocity[0] * retained
            glide.velocity[1] = Math.abs(this.camera.offsetY - before[1]) < 1e-6 ? 0 : glide.velocity[1] * retained
            if (Math.hypot(glide.velocity[0], glide.velocity[1]) < glideStopSpeed) {
                this.glide = null
                return
            }
            glide.request = requestAnimationFrame(step)
        }
        glide.request = requestAnimationFrame(step)
        this.glide = glide
    }

    stopGlide() {
        if (this.glide) {
            cancelAnimationFrame(this.glide.request)
            this.glide = null
        }
    }

    beginStroke(location, point) {
        this.endStroke()
        this.stroke = { raw: [point], screenLength: 0, lastLocation: location, stillLocation: location, stillTimer: null, straightEnd: null, straightShare: 0, predicted: [] }
        this.restartStill(location)
        this.requestOverlay()
    }

    extendStroke(location, point) {
        const stroke = this.stroke
        if (!stroke) {
            return
        }
        if (stroke.straightEnd !== null) {
            stroke.straightEnd = point
            return
        }
        const travelled = Math.hypot(location[0] - stroke.lastLocation[0], location[1] - stroke.lastLocation[1])
        if (travelled < minimumSampleSpacing) {
            return
        }
        stroke.screenLength += travelled
        stroke.lastLocation = location
        stroke.raw.push(point)
        if (Math.hypot(location[0] - stroke.stillLocation[0], location[1] - stroke.stillLocation[1]) > tokens.ink.straighten_tolerance_points) {
            this.restartStill(location)
        }
    }

    restartStill(location) {
        const stroke = this.stroke
        clearTimeout(stroke.stillTimer)
        stroke.stillLocation = location
        stroke.stillTimer = setTimeout(() => this.straightenStroke(), duration("stroke_straighten_hold"))
    }

    straightenStroke() {
        const stroke = this.stroke
        if (!stroke || stroke.straightEnd !== null || stroke.screenLength < minimumStraightLength) {
            return
        }
        stroke.straightEnd = stroke.raw[stroke.raw.length - 1]
        stroke.straightShare = 0
        stroke.predicted = []
        const start = performance.now()
        const step = (now) => {
            if (this.stroke !== stroke) {
                return
            }
            const progress = Math.min(1, (now - start) / duration("stroke_straighten_snap"))
            const inverse = 1 - progress
            stroke.straightShare = 1 - inverse * inverse
            this.drawOverlay()
            if (progress < 1) {
                this.snap = requestAnimationFrame(step)
            }
        }
        this.snap = requestAnimationFrame(step)
    }

    snappedEnd(stroke) {
        return axisSnapped(stroke.raw[0], stroke.straightEnd ?? stroke.raw[stroke.raw.length - 1])
    }

    liveStrokePoints() {
        const stroke = this.stroke
        if (!stroke) {
            return []
        }
        const smooth = smoothStroke([...stroke.raw, ...stroke.predicted], this.camera.scale, this.inkSmoothing)
        if (stroke.straightEnd === null) {
            return smooth
        }
        return straightened(smooth, stroke.raw[0], this.snappedEnd(stroke), stroke.straightShare)
    }

    finalStrokePoints() {
        const stroke = this.stroke
        if (!stroke) {
            return []
        }
        if (stroke.straightEnd !== null) {
            return smoothStroke([stroke.raw[0], this.snappedEnd(stroke)], this.camera.scale, this.inkSmoothing)
        }
        return smoothStroke(stroke.raw, this.camera.scale, this.inkSmoothing)
    }

    endStroke() {
        if (this.stroke) {
            clearTimeout(this.stroke.stillTimer)
        }
        cancelAnimationFrame(this.snap)
        this.snap = null
        this.stroke = null
        this.requestOverlay()
    }

    eraserReach() {
        return Math.max(this.eraserRadius, minimumEraserReach / this.camera.scale)
    }

    erase(sweepStart, sweepEnd, mode) {
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
            if (mode === "area") {
                const entry = this.areaErase.get(element.id)
                const pieces = entry?.pieces ?? [element.points]
                let isTouched = false
                const nextPieces = []
                for (const piece of pieces) {
                    const cut = cutStroke(piece, sweepStart, sweepEnd, strokeReach)
                    if (cut) {
                        isTouched = true
                        nextPieces.push(...cut)
                    } else {
                        nextPieces.push(piece)
                    }
                }
                if (isTouched) {
                    this.areaErase.set(element.id, { element, pieces: nextPieces, revision: (entry?.revision ?? 0) + 1 })
                    didErase = true
                }
            } else if (!this.pendingErased.includes(element.id) && isStrokeSwept(element, sweepStart, sweepEnd, reach)) {
                this.pendingErased.push(element.id)
                didErase = true
            }
        }
        if (didErase) {
            this.requestDraw()
        }
    }

    finishLasso(isMoved) {
        const polygon = this.lassoPoints
        this.lassoPoints = []
        this.requestOverlay()
        if (!isMoved || polygon.length < 3 || !this.page) {
            this.clearSelection()
            return
        }
        this.selectedIds = liveElements(this.page).filter((element) => this.isEnclosed(element, polygon)).map((element) => element.id)
        this.refreshSelection()
    }

    isEnclosed(element, polygon) {
        if (element.type === "stroke") {
            return lassoTouchesLine(polygon, element.points ?? [])
        }
        const rect = elementBounds(element)
        if (!rect) {
            return false
        }
        const corners = [[rect.x, rect.y], [rect.x + rect.width, rect.y], [rect.x + rect.width, rect.y + rect.height], [rect.x, rect.y + rect.height]]
        return lassoTouchesArea(polygon, corners)
    }

    refreshSelection() {
        if (!this.page || this.selectedIds.length === 0) {
            this.selectionBounds = null
            this.requestOverlay()
            return
        }
        const live = liveElements(this.page).filter((element) => this.selectedIds.includes(element.id))
        this.selectedIds = live.map((element) => element.id)
        this.selectionBounds = live.map(elementBounds).filter(Boolean).reduce((union, rect) => (union ? unionRect(union, rect) : rect), null)
        this.requestOverlay()
    }

    selectionScreenRect() {
        if (!this.selectionBounds) {
            return null
        }
        let moved = { ...this.selectionBounds, x: this.selectionBounds.x + this.selectionOffset[0], y: this.selectionBounds.y + this.selectionOffset[1] }
        if (this.selectionScaleAnchor) {
            const [anchorX, anchorY] = this.selectionScaleAnchor
            const factor = this.selectionScale
            moved = { x: anchorX + (moved.x - anchorX) * factor, y: anchorY + (moved.y - anchorY) * factor, width: moved.width * factor, height: moved.height * factor }
        }
        const [x, y] = this.camera.toScreen([moved.x, moved.y])
        return { x: x - selectionPadding, y: y - selectionPadding, width: moved.width * this.camera.scale + selectionPadding * 2, height: moved.height * this.camera.scale + selectionPadding * 2 }
    }

    finishSelectionMove(isMoved) {
        const offset = this.selectionOffset
        this.selectionStart = null
        this.selectionOffset = [0, 0]
        if (isMoved && (offset[0] !== 0 || offset[1] !== 0)) {
            this.callbacks.onMoveElements?.(this.selectedIds, offset)
        } else if (!isMoved && this.isSelectionTouchInside) {
            const rect = this.selectionScreenRect()
            const bounds = this.element.getBoundingClientRect()
            this.callbacks.onSelectionMenu?.({ ids: [...this.selectedIds], frame: { x: rect.x + bounds.left, y: rect.y + bounds.top, width: rect.width, height: rect.height } })
        } else if (!isMoved) {
            this.clearSelection()
        }
        this.refreshSelection()
        this.requestDraw()
    }

    clearSelection() {
        this.selectedIds = []
        this.callbacks.onSelectionMenu?.(null)
        this.refreshSelection()
    }

    textElementAt(point) {
        const elements = this.page ? liveElements(this.page).reverse() : []
        return elements.find((element) => {
            const rect = textRect(element)
            return rect && point[0] >= rect.x - 2 && point[0] <= rect.x + rect.width + 2 && point[1] >= rect.y - 2 && point[1] <= rect.y + rect.height + 2
        }) ?? null
    }

    startTextHoldTimer() {
        clearTimeout(this.textHoldTimer)
        this.textHoldTimer = setTimeout(() => {
            if (this.pressedText && !this.hasMoved) {
                this.isTextLifted = true
            }
        }, duration("text_move_hold"))
    }

    startHoldTimer() {
        clearTimeout(this.holdTimer)
        this.holdTimer = setTimeout(() => this.beginHold(), duration("menu_hold"))
    }

    beginHold() {
        if (!this.active || this.hasMoved) {
            return
        }
        this.isHolding = true
        this.isPanning = false
        this.endStroke()
        this.lassoPoints = []
        this.clearPendingFeedback()
        this.requestDraw()
        const bounds = this.element.getBoundingClientRect()
        this.callbacks.onHold?.([this.gestureStart[0] + bounds.left, this.gestureStart[1] + bounds.top], false)
    }

    cancelActiveGesture() {
        clearTimeout(this.holdTimer)
        clearTimeout(this.textHoldTimer)
        if (this.isHolding) {
            this.callbacks.onHoldEnd?.([-1, -1])
        }
        this.endStroke()
        this.lastErasePoint = null
        this.lassoPoints = []
        this.selectionStart = null
        this.selectionOffset = [0, 0]
        this.eraserAt = null
        this.clearPendingFeedback()
        this.resetGesture()
        this.requestDraw()
    }

    clearPendingFeedback() {
        this.pendingErased = []
        this.areaErase = new Map()
        this.pressedText = null
        this.isTextLifted = false
        this.textOffset = [0, 0]
    }

    resetGesture() {
        if (this.active) {
            try {
                this.element.releasePointerCapture(this.active.pointerId)
            } catch {
                this.active = null
            }
        }
        this.active = null
        this.isHolding = false
        this.isPanning = false
        this.hasMoved = false
    }
}

function isTyping(event) {
    const target = event.target
    return target instanceof HTMLInputElement || target instanceof HTMLTextAreaElement || target?.isContentEditable
}

function containsPoint(rect, point) {
    return Boolean(rect) && point[0] >= rect.x && point[0] <= rect.x + rect.width && point[1] >= rect.y && point[1] <= rect.y + rect.height
}

function unionRect(first, second) {
    const x = Math.min(first.x, second.x)
    const y = Math.min(first.y, second.y)
    return { x, y, width: Math.max(first.x + first.width, second.x + second.width) - x, height: Math.max(first.y + first.height, second.y + second.height) - y }
}

export function elementBounds(element) {
    if (element.type === "stroke") {
        const bounds = pointsBounds(element.points)
        if (!bounds) {
            return null
        }
        const reach = (element.width ?? 0) / 2
        return { x: bounds.minimumX - reach, y: bounds.minimumY - reach, width: bounds.maximumX - bounds.minimumX + reach * 2, height: bounds.maximumY - bounds.minimumY + reach * 2 }
    }
    if (element.type === "text") {
        return textRect(element)
    }
    return importRect(element)
}
