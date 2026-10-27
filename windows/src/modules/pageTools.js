import { create } from "./components.js"
import { colorPanel, iconButton, sizeSlider, swatchButton, wheelButton } from "./controls.js"
import { popInNow, popOut } from "./motion.js"
import { separator, slideWash } from "./navigation.js"
import {
    activeTool,
    addColorPreset,
    addWidthPreset,
    colorPresets,
    drawingTools,
    eraserMode,
    eraserRadius,
    isSameWidth,
    paperStyle,
    removeColorPreset,
    removeWidthPreset,
    setActiveTool,
    setEraserMode,
    setEraserRadius,
    setToolColor,
    setTextFontSize,
    setToolWidth,
    textFontSize,
    toolColor,
    toolWidth,
    widthPresets,
} from "./preferences.js"
import { inkOnPaper, isLight, tokens, withAlpha } from "./tokens.js"

const previewDiameterRange = [4, 20]
const toolLabels = { pen: "Pen", marker: "Marker", eraser: "Eraser", text: "Text" }
const eraserModeGlyphs = { stroke: "erase_stroke", area: "erase_area" }
const eraserModeLabels = { stroke: "Whole line", area: "Precise" }
const millimetresPerPoint = 0.35278

export function pointSize(millimetres) {
    return String(Math.round(millimetres / millimetresPerPoint))
}

function captionButton({ caption, label, onPress }) {
    const button = create("button", "tool-nav-button caption-button pressable", create("span", "tool-nav-caption", caption))
    button.type = "button"
    button.setAttribute("aria-label", label)
    button.title = label
    button.addEventListener("pointerdown", (event) => event.stopPropagation())
    button.addEventListener("click", (event) => {
        event.stopPropagation()
        onPress()
    })
    return button
}

function shareOf(value, [minimum, maximum]) {
    return Math.log(value / minimum) / Math.log(maximum / minimum)
}

function valueAt(share, [minimum, maximum]) {
    return minimum * Math.pow(maximum / minimum, share)
}

function previewDiameter(share) {
    return previewDiameterRange[0] + (previewDiameterRange[1] - previewDiameterRange[0]) * share
}

function presetRow() {
    const row = create("span", "swatch-row")
    const buttons = new Map()
    const sync = (values, makeButton) => {
        for (const [value, button] of buttons) {
            if (!values.includes(value)) {
                buttons.delete(value)
                button.style.pointerEvents = "none"
                popOut(button).finished.then(() => button.remove()).catch(() => button.remove())
            }
        }
        values.forEach((value, index) => {
            let button = buttons.get(value)
            if (!button) {
                button = makeButton(value)
                buttons.set(value, button)
                const following = values.slice(index + 1).map((candidate) => buttons.get(candidate)).find((candidate) => candidate?.isConnected)
                row.insertBefore(button, following ?? null)
                if (row.isConnected) {
                    popInNow(button)
                }
            }
        })
        return buttons
    }
    return { row, sync }
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
        if (session) {
            const color = inkOnPaper(session.element.color ?? tokens.text.color, paperStyle())
            this.nav.show("page-typing", [[
                { id: "text-size", caption: pointSize(session.element.font_size ?? textFontSize()), label: "Font size", tint: tokens.palette.text_bright, action: () => this.toggleSubNav("text-size", "text-size") },
                { id: "text-color", glyph: "text", label: "Text colour", tint: isLight(color) ? color : tokens.palette.text_bright, swatch: color, isTinted: true, action: () => this.toggleSubNav("text-color", "text-color") },
            ], [
                { id: "finish-text", glyph: "check", label: "Done", tint: tokens.semantic.create, isTinted: true, action: () => library.finishText() },
            ]], { isCarriable: true })
            this.controls?.update()
            return
        }
        if (this.controls?.isTyping) {
            this.closeSubNav()
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
        const more = [{ id: "page-menu", glyph: "more", label: "Page menu", action: (button) => this.screen.showPageMenu({ around: button.getBoundingClientRect() }) }]
        this.nav.show("page-tools", [toolItems, more], { selectedId: activeTool(), isCarriable: true })
        this.controls?.update()
    }

    pressTool(tool) {
        if (activeTool() === tool) {
            if (tool === "text") {
                this.toggleSubNav("text-size", "text")
            } else if (this.nav.isSubNavOpen(tool)) {
                this.closeSubNav()
            } else {
                this.openSubNav(tool)
            }
            return
        }
        this.closeSubNav()
        setActiveTool(tool)
    }

    toggleSubNav(key, anchorId) {
        if (this.nav.isSubNavOpen(key)) {
            this.closeSubNav()
        } else {
            this.openSubNav(key, anchorId)
        }
    }

    makeControls(key) {
        switch (key) {
        case "eraser": return this.eraserControls()
        case "text-size": return this.textSizeControls()
        case "text-color": return this.textColorControls()
        default: return this.inkControls(key)
        }
    }

    openSubNav(key, anchorId = key) {
        const controls = this.makeControls(key)
        this.controls = controls
        this.nav.openSubNav({
            key,
            anchorId,
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
        const sizes = presetRow()
        const addSizeButton = iconButton({ glyphName: "plus", label: "Save size", onPress: () => addWidthPreset(tool, toolWidth(tool)) })
        const colors = presetRow()
        const addColorButton = iconButton({ glyphName: "plus", label: "Save colour", onPress: () => addColorPreset(tool, toolColor(tool)) })
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
            const width = toolWidth(tool)
            const share = shareOf(width, range)
            const inkColor = withAlpha(inkOnPaper(current, style), Math.max(0.6, tokens.tools[tool].opacity))
            slider.setShare(share)
            slider.setPreview({ diameter: previewDiameter(share), color: inkColor })
            const savedWidths = widthPresets(tool)
            const sizeButtons = sizes.sync(savedWidths, (value) => {
                const button = swatchButton({
                    color: inkColor,
                    label: `${value} mm`,
                    onSelect: () => setToolWidth(tool, value),
                    onRemove: () => removeWidthPreset(tool, value),
                })
                button.classList.add("size-preset")
                return button
            })
            for (const [value, button] of sizeButtons) {
                button.setState({ color: inkColor, isSelected: isSameWidth(value, width), diameter: previewDiameter(shareOf(value, range)) })
            }
            addSizeButton.setEnabled(!savedWidths.some((value) => isSameWidth(value, width)))
            const savedColors = colorPresets(tool)
            const colorButtons = colors.sync(savedColors, (color) => swatchButton({
                color,
                label: color,
                onSelect: () => setToolColor(tool, color),
                onRemove: () => removeColorPreset(tool, color),
            }))
            for (const [color, button] of colorButtons) {
                button.setState({ color: inkOnPaper(color, style), isSelected: color === current.toUpperCase() })
            }
            addColorButton.setEnabled(!savedColors.includes(current.toUpperCase()))
            if (panel && this.nav.panel?.element === panel) {
                panel.setColor(inkOnPaper(current, style))
            } else {
                wheel.classList.remove("is-open")
            }
        }
        return { children: [slider, separator(), sizes.row, addSizeButton, separator(), colors.row, addColorButton, separator(), wheel], update }
    }

    textSizeControls() {
        const library = this.app.library
        const range = tokens.text.font_size_range
        const currentSize = () => library.textEditing?.element.font_size ?? textFontSize()
        const choose = (size) => {
            setTextFontSize(size)
            library.styleText({ font_size: textFontSize() })
        }
        const slider = sizeSlider({
            orientation: this.nav.orientation,
            share: shareOf(currentSize(), range),
            onChange: (share) => choose(valueAt(share, range)),
        })
        const presets = tokens.text.font_size_presets.map((size) => {
            const button = captionButton({ caption: pointSize(size), label: `${pointSize(size)} pt`, onPress: () => choose(size) })
            button.size = size
            return button
        })
        const update = () => {
            const size = currentSize()
            slider.setShare(shareOf(size, range))
            slider.setPreview({ diameter: previewDiameter(shareOf(size, range)), color: tokens.palette.text_bright })
            for (const button of presets) {
                button.classList.toggle("is-selected", pointSize(button.size) === pointSize(size))
            }
        }
        return { children: [slider, separator(), create("span", "swatch-row", ...presets)], update, isTyping: Boolean(library.textEditing) }
    }

    textColorControls() {
        const library = this.app.library
        const currentColor = () => library.textEditing?.element.color ?? tokens.text.color
        const choose = (color) => library.styleText({ color: color.toUpperCase() })
        const swatches = tokens.text.colors.map((color) => {
            const button = swatchButton({ color, label: color, onSelect: () => choose(color) })
            button.color = color
            return button
        })
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
                    color: inkOnPaper(currentColor(), paperStyle()),
                    onChange: (hex) => choose(inkOnPaper(hex, paperStyle())),
                })
                this.nav.openPanel(panel, wheel)
                wheel.classList.add("is-open")
            },
        })
        const update = () => {
            const style = paperStyle()
            const current = currentColor().toUpperCase()
            for (const button of swatches) {
                button.setState({ color: inkOnPaper(button.color, style), isSelected: button.color === current })
            }
            if (panel && this.nav.panel?.element === panel) {
                panel.setColor(inkOnPaper(current, style))
            } else {
                wheel.classList.remove("is-open")
            }
        }
        return { children: [create("span", "swatch-row", ...swatches), separator(), wheel], update, isTyping: true }
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
