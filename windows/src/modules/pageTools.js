import { create } from "./components.js"
import { colorPanel, iconButton, sizeSlider, swatchButton, wheelButton } from "./controls.js"
import { popInNow, popOut } from "./motion.js"
import { separator, slideWash } from "./navigation.js"
import {
    activeTool,
    addColorPreset,
    colorPresets,
    drawingTools,
    eraserMode,
    eraserRadius,
    paperStyle,
    removeColorPreset,
    setActiveTool,
    setEraserMode,
    setEraserRadius,
    setToolColor,
    setToolWidth,
    toolColor,
    toolWidth,
} from "./preferences.js"
import { inkOnPaper, isLight, tokens, withAlpha } from "./tokens.js"

const previewDiameterRange = [4, 20]
const toolLabels = { pen: "Pen", marker: "Marker", eraser: "Eraser", text: "Text" }
const eraserModeGlyphs = { stroke: "erase_stroke", area: "erase_area" }
const eraserModeLabels = { stroke: "Whole line", area: "Precise" }

function shareOf(value, [minimum, maximum]) {
    return Math.log(value / minimum) / Math.log(maximum / minimum)
}

function valueAt(share, [minimum, maximum]) {
    return minimum * Math.pow(maximum / minimum, share)
}

function previewDiameter(share) {
    return previewDiameterRange[0] + (previewDiameterRange[1] - previewDiameterRange[0]) * share
}

export class PageTools {
    constructor(screen) {
        this.screen = screen
        this.app = screen.app
        this.nav = screen.app.nav
        this.controls = null
        this.keyDown = (event) => {
            if (event.key === "Escape" && this.nav.subNav) {
                this.closeSubNav()
            }
        }
        window.addEventListener("keydown", this.keyDown)
    }

    destroy() {
        window.removeEventListener("keydown", this.keyDown)
        this.closeSubNav()
    }

    closeSubNav() {
        this.nav.closeSubNav()
    }

    canvasTool() {
        const tool = activeTool()
        if (tool === "text") {
            return { kind: "text" }
        }
        if (tool === "eraser") {
            return { kind: "eraser", radius: eraserRadius(), mode: eraserMode() }
        }
        return { kind: "ink", tool, color: toolColor(tool), width: toolWidth(tool) }
    }

    displayColor(tool) {
        return inkOnPaper(toolColor(tool), paperStyle())
    }

    update(session) {
        const library = this.app.library
        const pageId = this.screen.pageId
        if (session) {
            this.nav.show("page-typing", [[
                { id: "typing", glyph: "text", label: "Typing", tint: tokens.palette.accent, action: () => {} },
                { id: "finish-text", glyph: "check", label: "Done", tint: tokens.semantic.create, isTinted: true, action: () => library.finishText() },
            ]], { selectedId: "typing", isCarriable: true })
            return
        }
        const toolItems = [
            ...drawingTools.map((tool) => {
                const color = this.displayColor(tool)
                return {
                    id: tool,
                    glyph: tool,
                    label: toolLabels[tool],
                    tint: isLight(color) ? color : tokens.palette.text_bright,
                    swatch: color,
                    action: () => this.pressTool(tool),
                }
            }),
            { id: "eraser", glyph: "eraser", label: toolLabels.eraser, tint: tokens.semantic.destructive, action: () => this.pressTool("eraser") },
            { id: "text", glyph: "text", label: toolLabels.text, tint: tokens.palette.accent, action: () => this.pressTool("text") },
        ]
        const history = [
            { id: "undo", glyph: "undo", label: "Undo", isEnabled: library.canUndo(pageId), action: () => library.undo(pageId) },
            { id: "redo", glyph: "redo", label: "Redo", isEnabled: library.canRedo(pageId), action: () => library.redo(pageId) },
        ]
        const more = [{ id: "page-menu", glyph: "more", label: "Page menu", action: (button) => this.screen.showPageMenu({ around: button.getBoundingClientRect() }) }]
        this.nav.show("page-tools", [toolItems, history, more], { selectedId: activeTool(), isCarriable: true })
        this.controls?.update()
    }

    pressTool(tool) {
        if (activeTool() === tool) {
            if (tool === "text") {
                return
            }
            if (this.nav.isSubNavOpen(tool)) {
                this.closeSubNav()
            } else {
                this.openSubNav(tool)
            }
            return
        }
        this.closeSubNav()
        setActiveTool(tool)
    }

    openSubNav(tool) {
        const controls = tool === "eraser" ? this.eraserControls() : this.inkControls(tool)
        this.controls = controls
        this.nav.openSubNav({
            key: tool,
            anchorId: tool,
            children: controls.children,
            onClose: () => {
                if (this.controls === controls) {
                    this.controls = null
                }
            },
        })
        controls.update()
    }

    inkControls(tool) {
        const orientation = this.nav.orientation
        const range = tokens.tools[tool].width_range
        const slider = sizeSlider({
            orientation,
            share: shareOf(toolWidth(tool), range),
            onChange: (share) => setToolWidth(tool, valueAt(share, range)),
        })
        const swatchRow = create("span", "swatch-row")
        const swatches = new Map()
        const addButton = iconButton({ glyphName: "plus", label: "Save colour", onPress: () => addColorPreset(tool, toolColor(tool)) })
        let panel = null
        const wheel = wheelButton({
            label: "Colour wheel",
            onPress: () => {
                if (panel && this.nav.panel?.element === panel) {
                    this.nav.closePanel()
                    panel = null
                    wheel.classList.remove("is-open")
                    return
                }
                panel = colorPanel({
                    color: this.displayColor(tool),
                    onChange: (hex) => setToolColor(tool, inkOnPaper(hex, paperStyle())),
                })
                this.nav.openPanel(panel, wheel)
                wheel.classList.add("is-open")
            },
        })
        const update = () => {
            const style = paperStyle()
            const current = toolColor(tool)
            const share = shareOf(toolWidth(tool), range)
            slider.setShare(share)
            slider.setPreview({ diameter: previewDiameter(share), color: withAlpha(inkOnPaper(current, style), Math.max(0.6, tokens.tools[tool].opacity)) })
            const presets = colorPresets(tool)
            for (const [color, button] of swatches) {
                if (!presets.includes(color)) {
                    swatches.delete(color)
                    button.style.pointerEvents = "none"
                    popOut(button).finished.then(() => button.remove()).catch(() => button.remove())
                }
            }
            for (const color of presets) {
                let button = swatches.get(color)
                if (!button) {
                    button = swatchButton({
                        color,
                        label: color,
                        onSelect: () => setToolColor(tool, color),
                        onRemove: () => removeColorPreset(tool, color),
                    })
                    swatches.set(color, button)
                    swatchRow.append(button)
                    if (swatchRow.isConnected) {
                        popInNow(button)
                    }
                }
                button.setState({ color: inkOnPaper(color, style), isSelected: color === current.toUpperCase() || color === current })
            }
            addButton.setEnabled(!presets.includes(current.toUpperCase()) && !presets.includes(current))
            if (panel && this.nav.panel?.element === panel) {
                panel.setColor(inkOnPaper(current, style))
            } else {
                wheel.classList.remove("is-open")
            }
        }
        return { children: [slider, separator(), swatchRow, addButton, separator(), wheel], update }
    }

    eraserControls() {
        const orientation = this.nav.orientation
        const range = tokens.tools.eraser.radius_range
        const slider = sizeSlider({
            orientation,
            share: shareOf(eraserRadius(), range),
            onChange: (share) => setEraserRadius(valueAt(share, range)),
        })
        const wash = create("span", "tool-nav-wash")
        const modeButtons = new Map()
        const segment = create("span", "tool-nav-segment", wash)
        for (const mode of tokens.tools.eraser.modes) {
            const button = iconButton({ glyphName: eraserModeGlyphs[mode], label: eraserModeLabels[mode], onPress: () => setEraserMode(mode) })
            button.title = eraserModeLabels[mode]
            modeButtons.set(mode, button)
            segment.append(button)
        }
        let shownMode = null
        const update = () => {
            const share = shareOf(eraserRadius(), range)
            slider.setShare(share)
            slider.setPreview({ diameter: previewDiameter(share), color: withAlpha(tokens.semantic.destructive, 0.85) })
            const mode = eraserMode()
            for (const [candidate, button] of modeButtons) {
                button.classList.toggle("is-selected", candidate === mode)
                button.setTint(candidate === mode ? tokens.semantic.destructive : tokens.palette.text_body)
            }
            if (mode !== shownMode) {
                const isAnimated = shownMode !== null
                shownMode = mode
                requestAnimationFrame(() => slideWash(wash, modeButtons.get(mode), orientation, isAnimated))
            }
        }
        return { children: [slider, separator(), segment], update }
    }
}
