import { isStrokeHit, liveElements, roundedPoint, shouldAppend } from "./model.js"
import { Camera, StrokePathCache, drawPage, strokePath, textRect } from "./renderer.js"
import { duration } from "./motion.js"
import { tokens, withAlpha } from "./tokens.js"

const fitMargin = 24
const holdTolerance = 8
const minimumEraserReach = 6
const wheelZoomPerPixel = 0.0025

export class InkCanvas {
    constructor(callbacks) {
        this.callbacks = callbacks
        this.element = document.createElement("div")
        this.element.className = "ink-canvas"
        this.pageCanvas = document.createElement("canvas")
        this.liveCanvas = document.createElement("canvas")
        this.element.append(this.pageCanvas, this.liveCanvas)
        this.page = null
        this.tool = { kind: "ink", tool: "pen" }
        this.inkColor = "#1A1A1A"
        this.isReadOnly = false
        this.showsGuides = true
        this.hiddenElementIds = new Set()
        this.camera = new Camera()
        this.cache = new StrokePathCache()
        this.width = 0
        this.height = 0
        this.pixelRatio = window.devicePixelRatio || 1
        this.hasFitted = false
        this.activePointer = null
        this.touchPointers = new Map()
        this.livePoints = []
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
    }

    destroy() {
        window.removeEventListener("keydown", this.keyDown)
        window.removeEventListener("keyup", this.keyUp)
        clearTimeout(this.holdTimer)
    }

    configure({ page, tool, inkColor, showsGuides, hiddenElementIds, isReadOnly }) {
        const isNewPage = this.page?.id !== page.id
        const needsDraw = this.page !== page || this.showsGuides !== showsGuides || !sameSet(this.hiddenElementIds, hiddenElementIds)
        this.page = page
        this.tool = tool
        this.inkColor = inkColor
        this.showsGuides = showsGuides
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
        this.camera = Camera.fitting(this.page.extent, this.width, this.height, fitMargin)
        this.hasFitted = true
        this.cameraChanged()
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
        drawPage(this.pageCanvas.getContext("2d"), this.page, this.camera, {
            width: this.width,
            height: this.height,
            pixelRatio: this.pixelRatio,
            showsGuides: this.showsGuides,
            hiddenElementIds: new Set([...this.hiddenElementIds, ...this.pendingErased]),
            textOffsets,
            cache: this.cache,
        })
        if (!this.livePoints.length) {
            this.drawLive([])
        }
    }

    drawLive(points = this.livePoints) {
        const context = this.liveCanvas.getContext("2d")
        context.setTransform(1, 0, 0, 1, 0, 0)
        context.clearRect(0, 0, this.liveCanvas.width, this.liveCanvas.height)
        if (!points.length || this.tool.kind !== "ink") {
            return
        }
        const style = tokens.tools[this.tool.tool]
        context.setTransform(this.pixelRatio, 0, 0, this.pixelRatio, 0, 0)
        context.lineWidth = style.width * this.camera.scale
        context.lineCap = "round"
        context.lineJoin = "round"
        context.strokeStyle = withAlpha(this.inkColor, style.opacity)
        context.stroke(strokePath(points, (point) => this.camera.toScreen(point)))
    }

    cameraChanged() {
        this.drawLive()
        this.requestDraw()
        this.callbacks.onCameraChange?.(this.camera)
    }

    localPoint(event) {
        const rect = this.element.getBoundingClientRect()
        return [event.clientX - rect.left, event.clientY - rect.top]
    }

    pointerDown(event) {
        if (event.pointerType === "touch") {
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
            this.livePoints = [roundedPoint(point)]
            this.drawLive()
        } else if (this.tool.kind === "eraser") {
            this.erase(location)
        } else if (this.tool.kind === "text") {
            const element = this.textElement(point)
            if (element) {
                this.movingText = { id: element.id, origin: element.box, start: point }
            }
        }
    }

    pointerMove(event) {
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
        if (this.tool.kind === "ink") {
            for (const sample of samples.length ? samples : [event]) {
                const sampleLocation = this.localPoint(sample)
                const point = roundedPoint(this.camera.toPage(sampleLocation[0], sampleLocation[1]))
                if (shouldAppend(point, this.livePoints[this.livePoints.length - 1])) {
                    this.livePoints.push(point)
                }
            }
            const predicted = (event.getPredictedEvents ? event.getPredictedEvents() : []).map((sample) => {
                const sampleLocation = this.localPoint(sample)
                return this.camera.toPage(sampleLocation[0], sampleLocation[1])
            })
            this.drawLive([...this.livePoints, ...predicted])
        } else if (this.tool.kind === "eraser") {
            for (const sample of samples.length ? samples : [event]) {
                this.erase(this.localPoint(sample))
            }
        } else if (this.tool.kind === "text" && this.movingText && this.hasMoved) {
            const point = this.camera.toPage(location[0], location[1])
            this.textOffset = [point[0] - this.movingText.start[0], point[1] - this.movingText.start[1]]
            this.requestDraw()
        }
    }

    pointerUp(event) {
        if (event.pointerType === "touch") {
            this.touchPointers.delete(event.pointerId)
            if (this.touchPointers.size < 2) {
                this.pinchStart = null
            }
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
            this.livePoints = []
            this.drawLive()
            return
        }
        if (this.tool.kind === "ink") {
            if (!this.livePoints.length) {
                return
            }
            const points = this.livePoints
            this.livePoints = []
            this.drawLive(points)
            this.callbacks.onStroke?.(this.tool.tool, this.inkColor, points)
        } else if (this.tool.kind === "eraser") {
            if (this.pendingErased.length) {
                this.callbacks.onErase?.([...this.pendingErased])
            }
        } else if (this.tool.kind === "text") {
            const point = this.camera.toPage(location[0], location[1])
            const moving = this.movingText
            if (moving) {
                if (this.textOffsetMoved) {
                    this.callbacks.onTextMove?.(moving.id, { x: moving.origin.x + this.textOffset[0], y: moving.origin.y + this.textOffset[1], width: moving.origin.width })
                } else {
                    this.movingText = null
                    this.callbacks.onTextTap?.(point, moving.id)
                }
            } else {
                this.callbacks.onTextTap?.(point, null)
            }
        }
    }

    pointerCancel(event) {
        this.touchPointers.delete(event.pointerId)
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
        this.livePoints = []
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

    erase(location) {
        if (!this.page) {
            return
        }
        const point = this.camera.toPage(location[0], location[1])
        const reach = Math.max(tokens.tools.eraser.radius, minimumEraserReach / this.camera.scale)
        let didErase = false
        for (const element of liveElements(this.page)) {
            if (element.type === "stroke" && !this.pendingErased.includes(element.id) && isStrokeHit(element, point, reach)) {
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
        this.livePoints = []
        this.drawLive()
        this.clearPendingFeedback()
        this.requestDraw()
        this.callbacks.onHold?.(clientX, clientY, true)
    }

    clearPendingFeedback() {
        this.pendingErased = []
        this.movingText = null
        this.textOffset = [0, 0]
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
