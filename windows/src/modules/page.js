import { InkCanvas } from "./canvas.js"
import { ColorPickOverlay } from "./eyedropper.js"
import { create, pressable } from "./components.js"
import {
    KeyedList,
    SelectionRing,
    captionButton,
    colorPanel,
    colorVariations,
    groupEndButton,
    navIconButton,
    navMetrics,
    swatchButton,
    variationPanel,
    wheelButton,
} from "./controls.js"
import { slotsFromTokens } from "./menu.js"
import { purgeThumbnails } from "./grid.js"
import { isImportInverted, purgeImports } from "./imports.js"
import { cellContaining, liveElements } from "./model.js"
import { duration, tween } from "./motion.js"
import { popTogether } from "./pill.js"
import * as preferences from "./preferences.js"
import { importRect, placedBox, rowGap, snappedBox, snappedTop, textRect } from "./renderer.js"
import { codeLanguages, languageCaptions, languageTitles } from "./syntaxHighlighter.js"
import { RichTextEditor } from "./textEditor.js"
import { inkOnPaper, isLight, tokens, withAlpha } from "./tokens.js"

const millimetresPerPoint = 0.35278
const minimumTextWidth = 20
const editorInset = { top: 6, side: 22 }
const equalWidthTravel = 240
const previewDiameterRange = [4, 20]
const collapsedGroupCount = 2
const textInlineButtons = [
    { glyphName: "bold", flag: "isBold", label: "Bold" },
    { glyphName: "italic", flag: "isItalic", label: "Italic" },
    { glyphName: "underline", flag: "isUnderlined", label: "Underline" },
    { glyphName: "strikethrough", flag: "isStruck", label: "Strikethrough" },
    { glyphName: "underline_dashed", flag: "isDashedUnderlined", label: "Dashed underline" },
    { glyphName: "code", flag: "isCode", label: "Code" },
]
const textLineButtons = [
    { glyphName: "heading", lineKind: "heading", label: "Heading" },
    { glyphName: "list_bullet", lineKind: "bullet", label: "Bullet list" },
    { glyphName: "list_numbered", lineKind: "numbered", label: "Numbered list" },
]

function logShare(value, range) {
    return Math.log(value / range[0]) / Math.log(range[1] / range[0])
}

function logValue(share, range) {
    return range[0] * Math.pow(range[1] / range[0], share)
}

function previewDiameter(share) {
    return previewDiameterRange[0] + (previewDiameterRange[1] - previewDiameterRange[0]) * share
}

export function pixelCaption(millimetres) {
    const pixels = millimetres / millimetresPerPoint
    return pixels < 10 ? `${pixels.toFixed(1)}px` : `${Math.round(pixels)}px`
}

function capitalized(text) {
    return text.charAt(0).toUpperCase() + text.slice(1)
}

function presetElements(row) {
    return [...row.querySelectorAll(":scope > [data-preset]:not(.is-leaving)")]
}

export class PageScreen {
    constructor(app, notebookId, pageId) {
        this.app = app
        this.notebookId = notebookId
        this.pageId = pageId
        purgeThumbnails()
        this.element = create("div", "screen page-screen")
        this.flightLayer = create("div", "page-flight")
        this.flightInner = create("div", "page-flight-inner")
        this.canvasHost = create("div", "page-canvas")
        this.missing = create("div", "page-missing", create("span", "micro-label", "THIS NOTE WAS DELETED"))
        this.missing.hidden = true
        this.flightInner.append(this.canvasHost, this.missing)
        this.flightLayer.append(this.flightInner)
        this.selectionLayer = create("div", "selection-layer")
        this.eraserEdges = create("div", "eraser-edges", ...["top-left", "top-right", "bottom-right", "bottom-left"].map((corner) => create("span", `eraser-edge is-${corner}`)))
        this.eraserEdges.style.setProperty("--eraser-edge-reach", `${tokens.tools.eraser.edge_reach}px`)
        this.eraserEdges.style.setProperty("--eraser-edge-opacity", tokens.tools.eraser.edge_opacity)
        this.element.append(this.flightLayer, this.eraserEdges, this.selectionLayer)
        this.subNavKey = null
        this.lastSubNavKey = null
        this.panelKey = null
        this.variationColors = []
        this.variationMain = null
        this.variationSlot = null
        this.selectionColorIds = []
        this.eraserReturn = null
        this.previousTool = null
        this.selectionMenu = null
        this.equalWidth = tokens.tools.pen.width
        this.camera = null
        this.editor = null
        this.textStyleState = { style: {}, lineKind: "paragraph", codeLanguage: null, isPlainText: true }
        this.groupCache = new Map()
        this.canvas = new InkCanvas(this.callbacks())
        this.canvasHost.append(this.canvas.element)
        this.keyDown = (event) => this.handleKey(event)
        window.addEventListener("keydown", this.keyDown)
        this.startFlight()
    }

    destroy() {
        this.colorPick?.cancel()
        window.removeEventListener("keydown", this.keyDown)
        this.canvas.destroy()
        this.closeEditor()
        this.library.noteClosed(this.pageId)
        purgeImports()
    }

    get library() {
        return this.app.library
    }

    get session() {
        const session = this.library.textEditing
        return session?.pageId === this.pageId ? session : null
    }

    get activeTool() {
        return preferences.activeTool()
    }

    canvasTool() {
        const tool = this.activeTool
        if (tool === "eraser") {
            return { kind: "eraser", mode: preferences.eraserMode() }
        }
        if (tool === "text" || tool === "lasso") {
            return { kind: tool }
        }
        return { kind: "ink", tool }
    }

    startFlight() {
        const tile = this.app.navigator.openingTile
        if (!tile) {
            requestAnimationFrame(() => this.app.navigator.showPageChrome(true))
            return
        }
        this.app.navigator.openingTile = null
        const tileRadius = 18
        const openRadius = 24
        const fade = tokens.motion.shares.flight_corner_fade
        const apply = (progress) => {
            const full = this.element.getBoundingClientRect()
            const start = { x: tile.x - full.left, y: tile.y - full.top, width: tile.width, height: tile.height }
            const frame = {
                x: start.x * (1 - progress),
                y: start.y * (1 - progress),
                width: start.width + (full.width - start.width) * progress,
                height: start.height + (full.height - start.height) * progress,
            }
            const cover = Math.max(start.width / Math.max(1, full.width), start.height / Math.max(1, full.height))
            const scale = cover + (1 - cover) * progress
            const expand = Math.min(1, Math.max(0, (progress - (1 - fade)) / fade))
            const radius = (tileRadius + (openRadius - tileRadius) * progress) * (1 - expand)
            const centreX = frame.x + frame.width / 2 - full.width / 2
            const centreY = frame.y + frame.height / 2 - full.height / 2
            this.flightInner.style.transform = `translate(${centreX}px, ${centreY}px) scale(${scale})`
            const right = full.width - frame.x - frame.width
            const bottom = full.height - frame.y - frame.height
            this.flightLayer.style.clipPath = progress >= 1 ? "" : `inset(${frame.y}px ${right}px ${bottom}px ${frame.x}px round ${radius}px)`
        }
        apply(0)
        tween({
            milliseconds: duration("viewer_enter"),
            curveName: "power_two_out",
            onFrame: (eased) => apply(eased),
            onDone: () => {
                this.flightInner.style.transform = ""
                this.flightLayer.style.clipPath = ""
            },
        })
        setTimeout(() => this.app.navigator.showPageChrome(true), duration("viewer_enter") * tokens.motion.shares.chrome_arrival)
    }

    callbacks() {
        return {
            onCameraChange: (camera) => {
                this.camera = camera
                this.placeEditor()
            },
            onStroke: (tool, color, pieces, width) => this.library.addStrokes(this.pageId, tool, color, pieces, width),
            onErase: (ids) => this.library.erase(ids, this.pageId),
            onEraseArea: (replacements) => this.library.replaceStrokes(this.pageId, replacements),
            onTextTap: (point, elementId) => {
                if (this.library.textEditing) {
                    this.library.finishText()
                    return
                }
                if (elementId) {
                    this.library.editText(elementId, this.pageId)
                    return
                }
                const page = this.library.page(this.pageId)
                if (!page) {
                    return
                }
                const box = placedBox({ x: point[0], y: point[1], width: tokens.text.box_width }, page.extent, rowGap())
                this.library.beginText(this.pageId, [box.x, box.y])
            },
            onTextMove: (elementId, box) => this.library.moveText(elementId, this.pageId, box),
            onMoveElements: (ids, offset) => this.library.moveElements(ids, this.pageId, offset),
            onScaleElements: (ids, anchor, factor) => this.library.scaleElements(ids, this.pageId, anchor, factor),
            onSelectionMenu: (request) => {
                if (this.subNavKey === "selection-color") {
                    this.subNavKey = null
                    this.panelKey = null
                    this.refresh()
                }
                if (request) {
                    this.showSelectionMenu(request)
                } else {
                    this.setSelectionMenu(null)
                }
            },
            onInput: () => {
                this.library.noteInput(this.pageId)
                this.closePanel()
            },
            onHold: (point, isPointer, pagePoint) => this.showPageMenu(point, isPointer, pagePoint),
            onHoldMove: (point) => this.app.menu.drag(point),
            onHoldEnd: (point) => this.app.menu.release(point),
            onUndo: () => this.library.undo(this.pageId),
            onRedo: () => this.library.redo(this.pageId),
            onEraseLift: () => this.returnFromEraser(),
        }
    }

    handleKey(event) {
        const target = event.target
        if (target instanceof HTMLInputElement || target instanceof HTMLTextAreaElement) {
            return
        }
        const key = event.key.toLowerCase()
        if ((event.ctrlKey || event.metaKey) && key === "z") {
            event.preventDefault()
            if (event.shiftKey) {
                this.library.redo(this.pageId)
            } else {
                this.library.undo(this.pageId)
            }
        } else if ((event.ctrlKey || event.metaKey) && key === "y") {
            event.preventDefault()
            this.library.redo(this.pageId)
        }
    }

    chromeLeaving() {
        this.library.finishText()
        this.setSelectionMenu(null)
    }

    update() {
        const page = this.library.page(this.pageId)
        this.missing.hidden = Boolean(page)
        this.canvas.element.hidden = !page
        const session = this.session
        if (session?.element.id !== this.lastSessionId) {
            this.lastSessionId = session?.element.id
            this.subNavKey = null
            this.panelKey = null
        }
        if (this.subNavKey) {
            this.lastSubNavKey = this.subNavKey
        }
        this.eraserEdges.classList.toggle("is-shown", this.activeTool === "eraser")
        const inkTool = this.canvasTool().kind === "ink" ? this.activeTool : null
        if (page) {
            this.canvas.configure({
                page,
                tool: this.canvasTool(),
                inkColor: inkTool ? preferences.toolColor(inkTool) : "#1A1A1A",
                inkWidth: inkTool ? preferences.toolWidth(inkTool) : 0.5,
                eraserRadius: preferences.eraserRadius(),
                paperStyle: preferences.paperStyle(),
                showsGuides: preferences.showsGuides(),
                showsDividers: preferences.showsDividers(),
                showsBackdrop: preferences.showsAsciiBackground(),
                inkSmoothing: preferences.inkSmoothing(),
                textSnap: preferences.activeTextSnap(),
                hiddenElementIds: session ? new Set([session.element.id]) : new Set(),
                isReadOnly: this.library.isReadOnly(this.pageId),
                topInset: Math.max(0, this.app.chromeLayout.bottom),
            })
        }
        this.syncEditor(session, page)
        this.updateSelectionNav()
        this.app.nav.update(this.navProps())
    }

    navProps() {
        return {
            face: this.session ? "page-typing" : "page-tools",
            groups: this.navGroups(),
            selectedId: this.session ? null : this.activeTool,
            subNavKey: this.subNavKey,
            subNavigationGroups: this.orderedSubNavigationGroups(),
            panelKey: this.panelKey,
            panelAnchor: () => this.panelAnchorElement(),
            obstacles: Object.entries(this.app.chromeLayout.frames).filter(([key]) => key !== "title").map(([, frame]) => frame),
            keyboardHeight: this.app.keyboardHeight,
            isShown: this.app.navigator.isPageChromeShown && !this.app.navigator.isChromeLeaving,
            onReorderTools: (order) => preferences.setToolOrder(order),
            onReorderSubNavigation: (order) => {
                if (this.subNavKey) {
                    preferences.setSubNavigationOrder(order, this.subNavKey)
                }
            },
            panel: (key, orientation) => this.makePanel(key, orientation),
            updatePanel: (element, key) => this.updatePanel(element, key),
        }
    }

    refresh() {
        this.app.refresh()
    }

    displayColor(tool) {
        return inkOnPaper(preferences.toolColor(tool), preferences.paperStyle())
    }

    navGroups() {
        const session = this.session
        if (session) {
            const color = inkOnPaper(session.element.color ?? tokens.text.color, preferences.paperStyle())
            return [[
                { id: "text-style", caption: ".md", label: "Text styles", tint: tokens.tool_tints.markdown, isTinted: true, action: () => this.toggleSubNav("text-style") },
                { id: "text-code", glyph: "code", label: "Code", tint: tokens.tool_tints.code, isTinted: true, action: () => this.toggleSubNav("text-code") },
                { id: "text-color", glyph: "text", label: "Text colour", tint: isLight(color) ? color : tokens.palette.text_bright, isTinted: true, swatch: color, action: () => this.toggleSubNav("text-color") },
                { id: "text-snap", glyph: "snap", label: preferences.isTextSnapping() ? "Snap on" : "Snap off", tint: tokens.palette.accent, isTinted: preferences.isTextSnapping(), action: () => this.toggleTextSnap() },
            ], [
                { id: "finish-text", glyph: "check", label: "Done", tint: tokens.semantic.create, isTinted: true, action: () => this.library.finishText() },
            ]]
        }
        const tools = preferences.toolOrder().map((tool) => {
            switch (tool) {
            case "pen":
            case "marker": {
                const color = this.displayColor(tool)
                return { id: tool, glyph: tool, label: capitalized(tool), tint: tool === "marker" ? tokens.tool_tints.marker : tokens.palette.text_bright, isTinted: true, swatch: color, sizing: this.inkSizing(tool), action: () => this.press(tool) }
            }
            case "eraser":
                return { id: "eraser", glyph: "eraser_ring", label: "Eraser", tint: tokens.semantic.destructive, isTinted: true, sizing: this.eraserSizing(), action: () => this.press("eraser") }
            case "text":
                return { id: "text", glyph: "text", label: "Text", tint: tokens.semantic.navigation, isTinted: true, action: () => this.press("text") }
            default:
                return { id: "lasso", glyph: "lasso", label: "Lasso", tint: tokens.palette.accent, isTinted: true, action: () => this.press("lasso") }
            }
        })
        return [tools]
    }

    inkSizing(tool) {
        const range = tokens.tools[tool].width_range ?? [0.2, 2]
        return {
            share: logShare(preferences.toolWidth(tool), range),
            color: this.displayColor(tool),
            previewDiameter,
            caption: (share) => pixelCaption(logValue(share, range)),
            onChange: (share) => preferences.setToolWidth(tool, logValue(share, range)),
            canvasPreview: {
                diameter: (share) => logValue(share, range) * (this.camera?.scale ?? 1),
                color: withAlpha(this.displayColor(tool), tokens.tools[tool].opacity ?? 1),
                isRing: false,
            },
        }
    }

    eraserSizing() {
        const range = tokens.tools.eraser.radius_range
        return {
            share: logShare(preferences.eraserRadius(), range),
            color: tokens.semantic.destructive,
            previewDiameter,
            caption: (share) => pixelCaption(logValue(share, range) * 2),
            onChange: (share) => preferences.setEraserRadius(logValue(share, range)),
            canvasPreview: {
                diameter: (share) => logValue(share, range) * 2 * (this.camera?.scale ?? 1),
                color: tokens.semantic.destructive,
                isRing: true,
            },
        }
    }

    press(tool) {
        if (this.activeTool === tool) {
            if (tool === "lasso" || tool === "text") {
                return
            }
            this.toggleSubNav(tool)
            return
        }
        this.previousTool = this.activeTool
        this.eraserReturn = null
        if (this.subNavKey !== null && tool !== "lasso" && tool !== "text") {
            this.panelKey = null
            this.subNavKey = tool
        } else {
            this.subNavKey = null
            this.panelKey = null
        }
        preferences.setActiveTool(tool)
    }

    switchTool(tool) {
        if (tool === this.activeTool) {
            return
        }
        this.previousTool = this.activeTool
        if (this.subNavKey !== null) {
            this.panelKey = null
            this.subNavKey = tool === "lasso" || tool === "text" ? null : tool
        }
        preferences.setActiveTool(tool)
    }

    returnFromEraser() {
        if (!this.eraserReturn) {
            return
        }
        const tool = this.eraserReturn
        this.eraserReturn = null
        this.switchTool(tool)
    }

    toggleTextSnap() {
        this.panelKey = null
        if (!preferences.isTextSnapping()) {
            preferences.setTextSnapping(true)
            this.subNavKey = "text-snap"
        } else if (this.subNavKey === "text-snap") {
            preferences.setTextSnapping(false)
            this.subNavKey = null
        } else {
            this.subNavKey = "text-snap"
        }
        this.refresh()
    }

    toggleSubNav(key) {
        this.panelKey = null
        this.subNavKey = this.subNavKey === key ? null : key
        this.refresh()
    }

    closePanel() {
        if (this.panelKey !== null) {
            this.panelKey = null
            this.refresh()
        }
    }

    togglePanel() {
        this.panelKey = this.isWheelOpen() ? null : `wheel-${this.subNavKey ?? ""}`
        this.refresh()
    }

    isWheelOpen() {
        return Boolean(this.panelKey?.startsWith("wheel-"))
    }

    variationsKey(target) {
        return `${navMetrics.pillPanelPrefix}${target}`
    }

    isVariationAnchor(color, target) {
        return this.panelKey === this.variationsKey(target) && this.variationSlot === color.toUpperCase()
    }

    presetTool(target) {
        return target === "marker" ? "marker" : "pen"
    }

    isColorTarget(key) {
        return key === "pen" || key === "marker" || key === "text-color" || key === "selection-color"
    }

    currentColor(target) {
        switch (target) {
        case "text-color":
            return (this.session?.element.color ?? tokens.text.color).toUpperCase()
        case "selection-color": {
            const page = this.library.page(this.pageId)
            const element = page ? liveElements(page).find((candidate) => this.selectionColorIds.includes(candidate.id) && candidate.type !== "import") : null
            return (element?.color ?? tokens.text.color).toUpperCase()
        }
        default:
            return preferences.toolColor(target).toUpperCase()
        }
    }

    applyColor(target, color) {
        const normalized = color.toUpperCase()
        switch (target) {
        case "text-color":
            this.library.styleText({ color: normalized })
            break
        case "selection-color":
            if (this.selectionColorIds.length) {
                this.library.setColor(this.selectionColorIds, this.pageId, normalized)
            }
            break
        default:
            preferences.setToolColor(target, color)
        }
    }

    chooseColor(color, target) {
        const normalized = color.toUpperCase()
        if (this.isVariationAnchor(normalized, target)) {
            this.applyColor(target, color)
            this.closePanel()
            return
        }
        this.variationMain = normalized
        this.variationSlot = normalized
        this.variationColors = colorVariations(normalized)
        this.panelKey = this.variationsKey(target)
        this.applyColor(target, color)
    }

    pickVariation(variation, target) {
        const tool = this.presetTool(target)
        const slot = this.variationSlot
        if (!slot || variation === slot || preferences.colorPresets(tool).includes(variation)) {
            return
        }
        this.variationSlot = variation
        preferences.replaceColorPreset(tool, slot, variation)
        this.applyColor(target, variation)
    }

    panelAnchorElement() {
        if (this.isWheelOpen()) {
            return this.app.nav.subNavigation.content.querySelector(".wheel-button.is-open")
        }
        if (this.panelKey?.startsWith(navMetrics.pillPanelPrefix)) {
            return this.app.nav.subNavigation.content.querySelector(".swatch-button.is-panel-anchor")
        }
        return null
    }

    makePanel(key, orientation) {
        if (key.startsWith(navMetrics.pillPanelPrefix)) {
            const target = key.slice(navMetrics.pillPanelPrefix.length)
            const panel = variationPanel({ orientation, onPick: (variation) => this.pickVariation(variation, target) })
            this.updatePanel(panel, key)
            return panel
        }
        const panel = colorPanel({ color: this.wheelColor(), onChange: (hex) => this.applyWheel(hex), onPick: () => this.startColorPick(panel) })
        return panel
    }

    updatePanel(panel, key) {
        if (key.startsWith(navMetrics.pillPanelPrefix)) {
            if (!this.variationMain) {
                return
            }
            panel.update({ colors: this.variationColors, main: this.variationMain, selected: this.variationSlot ?? this.variationMain, display: (color) => inkOnPaper(color, preferences.paperStyle()) })
            return
        }
        panel.update?.({ color: this.wheelColor() })
    }

    wheelColor() {
        const key = this.subNavKey ?? this.lastSubNavKey
        return this.isColorTarget(key) ? inkOnPaper(this.currentColor(key), preferences.paperStyle()) : "#FFFFFF"
    }

    startColorPick(panel) {
        if (this.colorPick) {
            this.colorPick.cancel()
            return
        }
        panel.setPicking(true)
        const finish = () => {
            this.colorPick = null
            panel.setPicking(false)
        }
        this.colorPick = new ColorPickOverlay({
            host: this.app.overlayHost,
            sample: (point) => this.canvas.sampleColor(point),
            onPick: (hex) => {
                finish()
                this.applyWheel(hex)
                this.refresh()
            },
            onCancel: finish,
        })
    }

    applyWheel(hex) {
        const key = this.subNavKey
        if (this.isColorTarget(key)) {
            this.applyColor(key, inkOnPaper(hex, preferences.paperStyle()))
        }
    }

    orderedSubNavigationGroups() {
        const key = this.subNavKey ?? this.lastSubNavKey
        if (!key) {
            return []
        }
        const groups = this.subNavigationGroups(key)
        const order = preferences.subNavigationOrder(key)
        return [...order.map((id) => groups.find((group) => group.id === id)).filter(Boolean), ...groups.filter((group) => !order.includes(group.id))]
    }

    subNavigationGroups(key) {
        switch (key) {
        case "pen":
        case "marker":
            return this.inkGroups(key)
        case "eraser":
            return [this.eraserGroup()]
        case "text-style":
            return this.textStyleGroups()
        case "text-code":
            return this.textCodeGroups()
        case "text-snap":
            return [this.textSnapGroup()]
        case "text-color":
        case "selection-color":
            return this.colourGroups(key)
        default:
            return []
        }
    }

    group(id, make, refresh, onCollapse = null) {
        return {
            id,
            onCollapse,
            make: (orientation) => {
                const element = make(orientation)
                element.refresh = () => refresh(element, orientation)
                refresh(element, orientation)
                return element
            },
            update: (element) => element.refresh?.(),
            afterLayout: (element) => element?.afterLayout?.(),
        }
    }

    row(orientation) {
        return create("div", `nav-row is-${orientation}`)
    }

    isGroupCollapsed(id, count) {
        return count > collapsedGroupCount && preferences.isSubNavigationGroupCollapsed(id)
    }

    setGroupCollapsed(isCollapsing, id, count) {
        if (count <= collapsedGroupCount || this.isGroupCollapsed(id, count) === isCollapsing) {
            return false
        }
        preferences.setSubNavigationGroupCollapsed(isCollapsing, id)
        return true
    }

    inkGroups(tool) {
        const range = tokens.tools[tool].width_range ?? [0.2, 2]
        const sizesId = `${tool}-sizes`
        const sizes = this.group(sizesId, (orientation) => {
            const row = this.row(orientation)
            const ring = new SelectionRing(row, "selection-ring is-size")
            const plus = groupEndButton({ orientation, action: () => {
                const count = preferences.widthPresets(tool).length
                if (this.isGroupCollapsed(sizesId, count)) {
                    this.setGroupCollapsed(false, sizesId, count)
                } else {
                    preferences.addWidthPreset(tool, preferences.toolWidth(tool))
                }
            } })
            plus.dataset.revealedElement = ""
            row.append(plus)
            const list = new KeyedList(row, {
                make: (entry) => {
                    const swatch = swatchButton({ color: "#000", isSizePreset: true, orientation, onSelect: () => preferences.setToolWidth(tool, entry.preset), onRemove: () => preferences.removeWidthPreset(tool, entry.preset), onHold: ({ pointerId, point }) => this.app.nav.liftPreset({
                        pointerId,
                        point,
                        element: swatch,
                        elements: () => presetElements(row),
                        onReorder: (order) => {
                            const all = preferences.widthPresets(tool)
                            const shown = row.presets ?? all
                            preferences.setWidthPresets(tool, [...order.map((index) => shown[index]), ...all.slice(shown.length)])
                        },
                    }) })
                    swatch.dataset.revealedElement = ""
                    return swatch
                },
                isRevealed: () => this.app.nav.subNavigation.motion.areElementsShown,
            })
            row.list = list
            row.ring = ring
            row.plus = plus
            return row
        }, (row) => {
            const width = preferences.toolWidth(tool)
            const allPresets = preferences.widthPresets(tool)
            const isCollapsed = this.isGroupCollapsed(sizesId, allPresets.length)
            const presets = isCollapsed ? allPresets.slice(0, collapsedGroupCount) : allPresets
            const color = this.displayColor(tool)
            row.presets = presets
            row.list.sync(presets.map((preset) => ({ key: String(preset), preset })), { isSwitch: false })
            row.append(row.plus)
            let selected = null
            for (const preset of presets) {
                const swatch = row.list.elements.get(String(preset))
                const isSelected = preferences.isSameWidth(preset, width)
                swatch.update({ color, diameter: previewDiameter(logShare(preset, range)), isSelected })
                if (isSelected) {
                    selected = swatch
                }
            }
            row.plus.update({ isCollapsed, isEnabled: isCollapsed || !allPresets.some((preset) => preferences.isSameWidth(preset, width)) })
            row.afterLayout = () => row.ring.moveTo(selected)
            requestAnimationFrame(() => row.afterLayout())
        }, (isCollapsing) => this.setGroupCollapsed(isCollapsing, sizesId, preferences.widthPresets(tool).length))
        return [sizes, ...this.colourGroups(tool)]
    }

    colourGroups(target) {
        const tool = this.presetTool(target)
        const prefix = { "text-color": "text", "selection-color": "selection" }[target] ?? target
        const coloursId = `${prefix}-colours`
        const colours = this.group(coloursId, (orientation) => {
            const row = this.row(orientation)
            const ring = new SelectionRing(row, "selection-ring")
            const plus = groupEndButton({ orientation, action: () => {
                const count = preferences.colorPresets(tool).length
                if (this.isGroupCollapsed(coloursId, count)) {
                    this.setGroupCollapsed(false, coloursId, count)
                } else {
                    preferences.addColorPreset(tool, this.currentColor(target))
                }
            } })
            plus.dataset.revealedElement = ""
            row.append(plus)
            const list = new KeyedList(row, {
                make: (entry) => {
                    const swatch = swatchButton({ color: "#000", orientation, onSelect: () => this.chooseColor(row.colors[entry.index], target), onRemove: () => preferences.removeColorPreset(tool, row.colors[entry.index]), onHold: ({ pointerId, point }) => this.app.nav.liftPreset({
                        pointerId,
                        point,
                        element: swatch,
                        elements: () => presetElements(row),
                        onReorder: (order) => {
                            const all = preferences.colorPresets(tool)
                            preferences.setColorPresets(tool, [...order.map((index) => row.colors[index]), ...all.slice(row.colors.length)])
                        },
                    }) })
                    swatch.dataset.revealedElement = ""
                    return swatch
                },
                isRevealed: () => this.app.nav.subNavigation.motion.areElementsShown,
            })
            row.list = list
            row.ring = ring
            row.plus = plus
            return row
        }, (row) => {
            const current = this.currentColor(target)
            const allColors = preferences.colorPresets(tool)
            const isCollapsed = this.isGroupCollapsed(coloursId, allColors.length)
            const colors = isCollapsed ? allColors.slice(0, collapsedGroupCount) : allColors
            row.colors = colors
            row.list.sync(colors.map((color, index) => ({ key: String(index), index })), { isSwitch: false })
            row.append(row.plus)
            let selected = null
            colors.forEach((color, index) => {
                const swatch = row.list.elements.get(String(index))
                const isSelected = color.toUpperCase() === current
                const shown = inkOnPaper(color, preferences.paperStyle())
                const previous = swatch.dataset.color
                swatch.update({ color: shown, isSelected })
                if (previous && previous !== shown) {
                    swatch.querySelector(".swatch-dot").animate([{ background: previous }, { background: shown }], { duration: 160 })
                }
                swatch.dataset.color = shown
                swatch.classList.toggle("is-panel-anchor", this.isVariationAnchor(color, target))
                if (isSelected) {
                    selected = swatch
                }
            })
            row.plus.update({ isCollapsed, isEnabled: isCollapsed || !allColors.includes(current) })
            row.afterLayout = () => row.ring.moveTo(selected)
            requestAnimationFrame(() => row.afterLayout())
        }, (isCollapsing) => {
            if (!this.setGroupCollapsed(isCollapsing, coloursId, preferences.colorPresets(tool).length)) {
                return false
            }
            if (isCollapsing && this.panelKey === this.variationsKey(target)) {
                this.closePanel()
            }
            return true
        })
        const wheel = this.group(`${prefix}-wheel`, (orientation) => {
            const button = wheelButton({ orientation, action: () => this.togglePanel() })
            button.dataset.revealedElement = ""
            return button
        }, (button) => button.update({ isOpen: this.isWheelOpen() }))
        return [colours, wheel]
    }

    textSnapGroup() {
        return this.modeGroup("text-snap-modes", [
            { mode: "absolute", glyphName: "snap_absolute", label: "Absolute: snap to the page grid" },
            { mode: "relative", glyphName: "snap_relative", label: "Relative: move in grid steps from where the block was" },
        ], tokens.palette.accent, () => preferences.textSnapMode(), (mode) => preferences.setTextSnapMode(mode))
    }

    eraserGroup() {
        return this.modeGroup("eraser-modes", [
            { mode: "stroke", glyphName: "erase_stroke", label: "Erase strokes" },
            { mode: "area", glyphName: "erase_area", label: "Erase area" },
        ], tokens.semantic.destructive, () => preferences.eraserMode(), (mode) => preferences.setEraserMode(mode))
    }

    modeGroup(id, modes, tint, current, choose) {
        return this.group(id, (orientation) => {
            const row = this.row(orientation)
            const wash = create("span", "mode-wash")
            row.append(wash)
            row.wash = wash
            row.buttons = modes.map(({ mode, glyphName, label }) => {
                const button = navIconButton({ glyphName, tint, orientation, action: () => choose(mode) })
                button.setAttribute("aria-label", label)
                button.dataset.revealedElement = ""
                button.dataset.mode = mode
                row.append(button)
                return button
            })
            return row
        }, (row) => {
            const mode = current()
            let selected = null
            for (const button of row.buttons) {
                const isSelected = button.dataset.mode === mode
                button.update({ isSelected })
                if (isSelected) {
                    selected = button
                }
            }
            row.afterLayout = () => {
                const before = row.wash.dataset.placed ? row.wash.offsetLeft + row.wash.offsetTop * 10000 : null
                const from = { left: row.wash.offsetLeft, top: row.wash.offsetTop }
                row.wash.style.left = `${selected.offsetLeft}px`
                row.wash.style.top = `${selected.offsetTop}px`
                row.wash.style.width = `${selected.offsetWidth}px`
                row.wash.style.height = `${selected.offsetHeight}px`
                row.wash.dataset.placed = "true"
                if (before !== null && (from.left !== selected.offsetLeft || from.top !== selected.offsetTop)) {
                    row.wash.animate([{ translate: `${from.left - selected.offsetLeft}px ${from.top - selected.offsetTop}px` }, { translate: "0px 0px" }], { duration: 300, easing: "cubic-bezier(0.3, 1.2, 0.5, 1)" })
                }
            }
            requestAnimationFrame(() => row.afterLayout())
        })
    }

    requestTextStyle(command) {
        this.editor?.field.perform(command)
    }

    textStyleGroups() {
        const state = () => this.textStyleState
        const inline = this.group("text-inline-styles", (orientation) => {
            const row = this.row(orientation)
            row.buttons = textInlineButtons.map(({ glyphName, flag, label }) => {
                const button = navIconButton({ glyphName, tint: tokens.semantic.edit, orientation, action: () => this.requestTextStyle({ kind: "inline", flag }) })
                button.setAttribute("aria-label", label)
                button.classList.add("is-washed")
                button.dataset.revealedElement = ""
                button.flag = flag
                row.append(button)
                return button
            })
            return row
        }, (row) => {
            row.buttons.forEach((button) => button.update({ isSelected: Boolean(state().style[button.flag]) }))
        })
        const lines = this.group("text-line-styles", (orientation) => {
            const row = this.row(orientation)
            row.buttons = textLineButtons.map(({ glyphName, lineKind, label }) => {
                const button = navIconButton({ glyphName, tint: tokens.semantic.edit, orientation, action: () => this.requestTextStyle({ kind: "line", lineKind }) })
                button.setAttribute("aria-label", label)
                button.classList.add("is-washed")
                button.dataset.revealedElement = ""
                button.lineKind = lineKind
                row.append(button)
                return button
            })
            return row
        }, (row) => {
            row.buttons.forEach((button) => button.update({ isSelected: state().lineKind === button.lineKind }))
        })
        return [inline, lines]
    }

    textCodeGroups() {
        const languages = this.group("code-languages", (orientation) => {
            const row = this.row(orientation)
            row.ring = new SelectionRing(row, "selection-ring is-caption")
            row.buttons = codeLanguages.map((language) => {
                const button = captionButton({ caption: languageCaptions[language], action: () => this.requestTextStyle({ kind: "code", language }) })
                button.setAttribute("aria-label", languageTitles[language])
                button.dataset.revealedElement = ""
                button.language = language
                row.append(button)
                return button
            })
            return row
        }, (row) => {
            let selected = null
            row.buttons.forEach((button) => {
                const isSelected = this.textStyleState.codeLanguage === button.language
                button.update({ isSelected })
                if (isSelected) {
                    selected = button
                }
            })
            row.afterLayout = () => row.ring.moveTo(selected)
            requestAnimationFrame(() => row.afterLayout())
        })
        const plain = this.group("code-plain", (orientation) => {
            const row = this.row(orientation)
            row.ring = new SelectionRing(row, "selection-ring is-caption")
            row.button = captionButton({ caption: "Aa", action: () => this.requestTextStyle({ kind: "code", language: null }) })
            row.button.setAttribute("aria-label", "Normal text")
            row.button.dataset.revealedElement = ""
            row.append(row.button)
            return row
        }, (row) => {
            const isSelected = this.textStyleState.isPlainText
            row.button.update({ isSelected })
            row.afterLayout = () => row.ring.moveTo(isSelected ? row.button : null)
            requestAnimationFrame(() => row.afterLayout())
        })
        return [languages, plain]
    }

    selectPlaced(ids) {
        this.canvas.select(ids, this.library.page(this.pageId))
    }

    showSelectionMenu(request) {
        const page = this.library.page(this.pageId)
        const selected = page ? page.elements.filter((element) => !element.deleted && request.ids.includes(element.id)) : []
        const point = [request.frame.x + request.frame.width, request.frame.y]
        const slots = slotsFromTokens(tokens.menus.selection, {
            title: (action) => ({
                cut: "Cut",
                copy: "Copy",
                duplicate: "Duplicate",
                color: "Colour",
                equal_width: "Equal width",
            })[action] ?? action,
            isEnabled: (action) => {
                switch (action) {
                case "color": return selected.some((element) => element.type !== "import")
                case "equal_width": return selected.some((element) => element.type === "stroke")
                default: return selected.length > 0
                }
            },
            perform: (action) => {
                switch (action) {
                case "cut": this.library.cutElements(request.ids, this.pageId); break
                case "copy": this.library.copyElements(request.ids, this.pageId); break
                case "duplicate": this.selectPlaced(this.library.duplicate(request.ids, this.pageId)); break
                case "color": this.showSelectionColors(selected); break
                case "equal_width": this.setSelectionMenu(request); break
                default: break
                }
            },
        })
        this.app.menu.present(slots, point, "Selection")
    }

    showSelectionColors(elements) {
        this.selectionColorIds = elements.filter((element) => element.type !== "import").map((element) => element.id)
        if (!this.selectionColorIds.length) {
            return
        }
        this.panelKey = null
        this.subNavKey = "selection-color"
        this.refresh()
    }

    showPageMenu(point, isPointer, pagePoint) {
        const page = this.library.page(this.pageId)
        const isReadOnly = this.library.isReadOnly(this.pageId)
        const showsGuides = preferences.showsGuides()
        const showsDividers = preferences.showsDividers()
        const hasClipboard = this.library.clipboard.length > 0
        const heldImport = page ? liveElements(page).find((element) => {
            const rect = element.type === "import" ? importRect(element) : null
            return rect && pagePoint.x >= rect.x && pagePoint.x < rect.x + rect.width && pagePoint.y >= rect.y && pagePoint.y < rect.y + rect.height
        }) : null
        const isHeldImportInverted = heldImport ? isImportInverted(heldImport, preferences.paperStyle() === "dark") : false
        const actions = ["paste", "expand_columns", "shrink_columns", "expand_rows", "shrink_rows", "toggle_guides", "toggle_dividers", "invert_import", "delete_page"]
        const slots = slotsFromTokens(tokens.menus.page.filter((slot) => actions.includes(slot.action)), {
            title: (action) => ({
                paste: "Paste",
                expand_columns: "Add column",
                shrink_columns: "Remove column",
                expand_rows: "Add row",
                shrink_rows: "Remove row",
                toggle_guides: showsGuides ? "Guides off" : "Guides on",
                toggle_dividers: showsDividers ? "Cell lines off" : "Cell lines on",
                invert_import: isHeldImportInverted ? "Original PDF" : "Invert PDF",
                delete_page: "Delete note",
            })[action] ?? action,
            isEnabled: (action) => {
                switch (action) {
                case "paste": return hasClipboard && Boolean(page) && !isReadOnly
                case "expand_columns":
                case "expand_rows": return Boolean(page) && !isReadOnly
                case "shrink_columns": return Boolean(page) && !isReadOnly && page.extent.cols > 1
                case "shrink_rows": return Boolean(page) && !isReadOnly && page.extent.rows > 1
                case "toggle_dividers": return (page ? page.extent.cols * page.extent.rows : 1) > 1
                case "invert_import": return Boolean(heldImport) && !isReadOnly
                case "delete_page": return Boolean(page)
                default: return true
                }
            },
            perform: (action) => {
                switch (action) {
                case "paste": this.selectPlaced(this.library.paste(this.pageId, pagePoint)); break
                case "expand_columns": this.library.expand(this.pageId, true); break
                case "shrink_columns": this.library.removeCell(this.pageId, true, cellContaining(page.extent, pagePoint, true)); break
                case "expand_rows": this.library.expand(this.pageId, false); break
                case "shrink_rows": this.library.removeCell(this.pageId, false, cellContaining(page.extent, pagePoint, false)); break
                case "toggle_guides": preferences.setShowsGuides(!showsGuides); break
                case "toggle_dividers": preferences.setShowsDividers(!showsDividers); break
                case "invert_import": this.library.setInverted([heldImport.id], this.pageId, !isHeldImportInverted); break
                case "delete_page":
                    this.library.deletePage(this.pageId)
                    this.app.navigator.go({ kind: "notebook", notebookId: this.notebookId })
                    break
                default: break
                }
            },
        })
        this.app.menu.present(slots, point, "Note", isPointer)
    }

    setSelectionMenu(request) {
        const isSame = JSON.stringify(request) === JSON.stringify(this.selectionMenu)
        if (isSame) {
            return
        }
        const old = this.selectionNav
        if (old) {
            this.selectionNav = null
            old.style.pointerEvents = "none"
            popTogether(old, false).finished.then(() => old.remove(), () => old.remove())
        }
        this.selectionMenu = request
        if (request) {
            this.selectionNav = this.makeSelectionNav(request)
            this.selectionLayer.append(this.selectionNav)
            this.updateSelectionNav()
            popTogether(this.selectionNav, true)
        }
    }

    makeSelectionNav(request) {
        const range = tokens.tools.pen.width_range ?? [0.2, 2]
        const nav = create("div", "selection-nav")
        const apply = create("button", "selection-apply", "RESIZE TO EQUAL PX")
        pressable(apply)
        apply.addEventListener("click", () => this.library.setStrokeWidth(request.ids, this.pageId, this.equalWidth))
        const value = create("span", "selection-value", pixelCaption(this.equalWidth))
        value.setAttribute("aria-label", "Stroke width")
        let dragStart = null
        value.addEventListener("pointerdown", (event) => {
            value.setPointerCapture(event.pointerId)
            dragStart = { x: event.clientX, share: null }
        })
        value.addEventListener("pointermove", (event) => {
            if (!dragStart || Math.abs(event.clientX - dragStart.x) < navMetrics.sizingSlop && dragStart.share === null) {
                return
            }
            if (dragStart.share === null) {
                dragStart.share = logShare(this.equalWidth, range)
                dragStart.x = event.clientX
            }
            this.equalWidth = logValue(Math.min(1, Math.max(0, dragStart.share + (event.clientX - dragStart.x) / equalWidthTravel)), range)
            value.textContent = pixelCaption(this.equalWidth)
        })
        value.addEventListener("pointerup", () => {
            dragStart = null
        })
        nav.append(apply, create("span", "nav-separator is-horizontal"), value)
        return nav
    }

    updateSelectionNav() {
        const nav = this.selectionNav
        const request = this.selectionMenu
        if (!nav || !request) {
            return
        }
        const layer = this.element.getBoundingClientRect()
        const halfWidth = 150
        const x = Math.min(layer.width - halfWidth - navMetrics.edgeMargin, Math.max(halfWidth + navMetrics.edgeMargin, request.frame.x + request.frame.width / 2 - layer.left))
        const above = request.frame.y - layer.top - navMetrics.besideGap - 27
        const y = above > Math.max(this.app.chromeLayout.bottom - layer.top, 0) + 27 ? above : request.frame.y + request.frame.height - layer.top + navMetrics.besideGap + 27
        nav.style.left = `${x}px`
        nav.style.top = `${y}px`
    }

    syncEditor(session, page) {
        if (!session || !page || !session.element.box) {
            this.closeEditor()
            return
        }
        if (!this.editor || this.editor.elementId !== session.element.id) {
            this.closeEditor()
            this.openEditor(session)
        }
        const content = session.element.content ?? ""
        if (this.editor.field.markdown !== content) {
            this.editor.field.load(content)
        }
        this.placeEditor()
    }

    openEditor(session) {
        const frame = create("div", "text-editor")
        const field = new RichTextEditor({
            onChange: (markdown) => {
                this.library.updateText(markdown)
                this.placeEditor()
            },
            onStyleState: (state) => {
                this.textStyleState = state
                this.refresh()
            },
        })
        field.onEscape = () => this.library.finishText()
        const leftHandle = create("span", "text-handle is-left", create("span", "text-handle-bar"))
        const rightHandle = create("span", "text-handle is-right", create("span", "text-handle-bar"))
        frame.append(field.element, leftHandle, rightHandle)
        this.canvasHost.append(frame)
        this.editor = { elementId: session.element.id, frame, field }
        this.textStyleState = { style: {}, lineKind: "paragraph", codeLanguage: null, isPlainText: true }
        this.placeEditor()
        field.load(session.element.content ?? "")
        this.bindTextDrag(frame, (origin, translation) => snappedBox({ ...origin, x: origin.x + translation[0], y: origin.y + translation[1] }, origin, preferences.activeTextSnap()), true)
        this.bindTextDrag(leftHandle, (origin, translation) => {
            const shift = Math.min(translation[0], origin.width - minimumTextWidth)
            return { ...origin, x: origin.x + shift, width: origin.width - shift }
        })
        this.bindTextDrag(rightHandle, (origin, translation) => ({ ...origin, width: Math.max(minimumTextWidth, origin.width + translation[0]) }))
        requestAnimationFrame(() => field.focus())
    }

    focusEditor() {
        this.editor?.field.focus()
    }

    bindTextDrag(target, change, isBody = false) {
        let drag = null
        target.addEventListener("pointerdown", (event) => {
            const isInField = Boolean(this.editor?.field.element.contains(event.target))
            if (isBody && isInField && event.pointerType === "mouse") {
                return
            }
            if (isBody && event.target !== target && !isInField) {
                return
            }
            event.stopPropagation()
            drag = { start: [event.clientX, event.clientY], origin: null, pointerId: event.pointerId }
        })
        target.addEventListener("pointermove", (event) => {
            if (!drag || drag.pointerId !== event.pointerId || !this.camera) {
                return
            }
            const translation = [event.clientX - drag.start[0], event.clientY - drag.start[1]]
            if (!drag.origin) {
                if (Math.hypot(...translation) < 6) {
                    return
                }
                target.setPointerCapture(event.pointerId)
                drag.origin = this.session?.element.box
                event.preventDefault()
            }
            const session = this.session
            const page = this.library.page(this.pageId)
            if (!session || !page || !drag.origin) {
                return
            }
            const height = textRect(session.element)?.height ?? 0
            this.library.placeText(placedBox(change(drag.origin, [translation[0] / this.camera.scale, translation[1] / this.camera.scale]), page.extent, height))
            this.placeEditor()
        })
        const end = () => {
            drag = null
        }
        target.addEventListener("pointerup", end)
        target.addEventListener("pointercancel", end)
    }

    placeEditor() {
        const editor = this.editor
        const session = this.session
        const camera = this.camera
        if (!editor || !session || !camera) {
            return
        }
        const box = session.element.box
        const color = inkOnPaper(session.element.color ?? tokens.text.color, preferences.paperStyle())
        editor.field.setLook({ zoom: camera.scale, color, paperStyle: preferences.paperStyle(), writingFont: preferences.writingFont() })
        editor.field.element.style.width = `${box.width * camera.scale}px`
        editor.field.element.style.minHeight = `${rowGap() * camera.scale}px`
        editor.frame.style.left = `${box.x * camera.scale + camera.offsetX - editorInset.side}px`
        editor.frame.style.top = `${snappedTop(box.y) * camera.scale + camera.offsetY - editorInset.top}px`
    }

    closeEditor() {
        if (this.editor) {
            this.editor.field.destroy()
            this.editor.frame.remove()
            this.editor = null
        }
    }
}
