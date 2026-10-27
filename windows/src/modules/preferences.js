import { readSetting, writeSetting } from "./storage.js"
import { tokens } from "./tokens.js"

export const drawingTools = ["pen", "marker"]

const listeners = new Set()

export function subscribePreferences(listener) {
    listeners.add(listener)
    return () => listeners.delete(listener)
}

function changed() {
    for (const listener of listeners) {
        listener()
    }
}

function clamp(value, [minimum, maximum]) {
    return Math.min(maximum, Math.max(minimum, value))
}

export function paperStyle() {
    const style = readSetting("paperStyle", tokens.page.default_style)
    return tokens.page.styles[style] ? style : tokens.page.default_style
}

export function togglePaperStyle() {
    writeSetting("paperStyle", paperStyle() === "dark" ? "light" : "dark")
    changed()
}

export function toolColor(tool) {
    return readSetting(`${tool}Color`, tokens.tools[tool].colors[0])
}

export function setToolColor(tool, color) {
    writeSetting(`${tool}Color`, color.toUpperCase())
    changed()
}

export function toolWidth(tool) {
    return clamp(readSetting(`${tool}Width`, tokens.tools[tool].width), tokens.tools[tool].width_range)
}

export function setToolWidth(tool, width) {
    writeSetting(`${tool}Width`, clamp(width, tokens.tools[tool].width_range))
    changed()
}

const widthPrecision = 100

function roundedWidth(width) {
    return Math.round(width * widthPrecision) / widthPrecision
}

export function isSameWidth(first, second) {
    return roundedWidth(first) === roundedWidth(second)
}

export function widthPresets(tool) {
    const stored = readSetting(`${tool}WidthPresets`, null)
    return Array.isArray(stored) ? stored : [...tokens.tools[tool].width_presets]
}

export function addWidthPreset(tool, width) {
    const presets = widthPresets(tool)
    const rounded = roundedWidth(clamp(width, tokens.tools[tool].width_range))
    if (!presets.some((candidate) => isSameWidth(candidate, rounded))) {
        writeSetting(`${tool}WidthPresets`, [...presets, rounded].sort((first, second) => first - second))
        changed()
    }
}

export function removeWidthPreset(tool, width) {
    writeSetting(`${tool}WidthPresets`, widthPresets(tool).filter((candidate) => candidate !== width))
    changed()
}

export function colorPresets(tool) {
    const stored = readSetting(`${tool}Presets`, null)
    return Array.isArray(stored) ? stored : [...tokens.tools[tool].colors]
}

export function addColorPreset(tool, color) {
    const presets = colorPresets(tool)
    const normalized = color.toUpperCase()
    if (!presets.includes(normalized)) {
        writeSetting(`${tool}Presets`, [...presets, normalized])
        changed()
    }
}

export function removeColorPreset(tool, color) {
    writeSetting(`${tool}Presets`, colorPresets(tool).filter((candidate) => candidate !== color))
    changed()
}

export function eraserRadius() {
    return clamp(readSetting("eraserRadius", tokens.tools.eraser.radius), tokens.tools.eraser.radius_range)
}

export function setEraserRadius(radius) {
    writeSetting("eraserRadius", clamp(radius, tokens.tools.eraser.radius_range))
    changed()
}

export function eraserMode() {
    const mode = readSetting("eraserMode", tokens.tools.eraser.modes[0])
    return tokens.tools.eraser.modes.includes(mode) ? mode : tokens.tools.eraser.modes[0]
}

export function setEraserMode(mode) {
    writeSetting("eraserMode", mode)
    changed()
}

export function activeTool() {
    const tool = readSetting("activeTool", "pen")
    return [...drawingTools, "eraser", "text"].includes(tool) ? tool : "pen"
}

export function setActiveTool(tool) {
    writeSetting("activeTool", tool)
    changed()
}

export function navPlacement() {
    return readSetting("navPlacement", null)
}

export function setNavPlacement(placement) {
    writeSetting("navPlacement", placement)
}
