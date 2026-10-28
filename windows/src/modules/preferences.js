import { readSetting, writeSetting } from "./storage.js"
import { tokens } from "./tokens.js"

export const drawingTools = ["pen", "marker"]
export const allTools = ["pen", "marker", "eraser", "text", "lasso"]

const listeners = new Set()

export function subscribePreferences(listener) {
    listeners.add(listener)
    return () => listeners.delete(listener)
}

function write(key, value) {
    writeSetting(key, value)
    for (const listener of listeners) {
        listener()
    }
}

function clamp(value, [minimum, maximum]) {
    return Math.min(maximum, Math.max(minimum, value))
}

function widthRange(tool) {
    return tokens.tools[tool].width_range ?? [0.1, 20]
}

export function paperStyle() {
    const style = readSetting("paperStyle", tokens.page.default_style)
    return tokens.page.styles[style] ? style : tokens.page.default_style
}

export function setPaperStyle(style) {
    if (tokens.page.styles[style]) {
        write("paperStyle", style)
    }
}

export function showsAsciiBackground() {
    return readSetting("showsAsciiBackground", false)
}

export function setShowsAsciiBackground(value) {
    write("showsAsciiBackground", value)
}

export function isAsciiBackgroundMoving() {
    return readSetting("isAsciiBackgroundMoving", true)
}

export function setAsciiBackgroundMoving(value) {
    write("isAsciiBackgroundMoving", value)
}

export function asciiBackgroundOpacity() {
    return clamp(readSetting("asciiBackgroundOpacity", tokens.background.opacity), tokens.background.opacity_range)
}

export function setAsciiBackgroundOpacity(value) {
    write("asciiBackgroundOpacity", clamp(value, tokens.background.opacity_range))
}

export function doesAsciiBackgroundMoveInCanvas() {
    return readSetting("doesAsciiBackgroundMoveInCanvas", true)
}

export function setAsciiBackgroundMovesInCanvas(value) {
    write("doesAsciiBackgroundMoveInCanvas", value)
}

export function asciiBackgroundColor() {
    return readSetting("asciiBackgroundColor", tokens.background.colors[0])
}

export function setAsciiBackgroundColor(color) {
    write("asciiBackgroundColor", color.toUpperCase())
}

export function showsGuides() {
    return readSetting("showsGuides", true)
}

export function setShowsGuides(value) {
    write("showsGuides", value)
}

export function showsDividers() {
    return readSetting("showsDividers", true)
}

export function setShowsDividers(value) {
    write("showsDividers", value)
}

export function activeTool() {
    const tool = readSetting("activeTool", "pen")
    return allTools.includes(tool) ? tool : "pen"
}

export function setActiveTool(tool) {
    write("activeTool", tool)
}

export function toolColor(tool) {
    return readSetting(`${tool}Color`, tokens.tools[tool].colors[0])
}

export function setToolColor(tool, color) {
    write(`${tool}Color`, color.toUpperCase())
}

export function toolWidth(tool) {
    return clamp(readSetting(`${tool}Width`, tokens.tools[tool].width), widthRange(tool))
}

export function setToolWidth(tool, width) {
    write(`${tool}Width`, clamp(width, widthRange(tool)))
}

export function roundedWidth(width) {
    return Math.round(width * 100) / 100
}

export function isSameWidth(first, second) {
    return roundedWidth(first) === roundedWidth(second)
}

export function widthPresets(tool) {
    const stored = readSetting(`${tool}WidthPresets`, null)
    return Array.isArray(stored) ? stored : [...(tokens.tools[tool].width_presets ?? [])]
}

export function addWidthPreset(tool, width) {
    const rounded = roundedWidth(clamp(width, widthRange(tool)))
    const presets = widthPresets(tool)
    if (!presets.some((candidate) => isSameWidth(candidate, rounded))) {
        write(`${tool}WidthPresets`, [...presets, rounded].sort((first, second) => first - second))
    }
}

export function removeWidthPreset(tool, width) {
    write(`${tool}WidthPresets`, widthPresets(tool).filter((candidate) => candidate !== width))
}

export function colorPresets(tool) {
    const stored = readSetting(`${tool}Presets`, null)
    return Array.isArray(stored) ? stored : [...tokens.tools[tool].colors]
}

export function addColorPreset(tool, color) {
    const normalized = color.toUpperCase()
    const presets = colorPresets(tool)
    if (!presets.includes(normalized)) {
        write(`${tool}Presets`, [...presets, normalized])
    }
}

export function removeColorPreset(tool, color) {
    write(`${tool}Presets`, colorPresets(tool).filter((candidate) => candidate !== color))
}

export function replaceColorPreset(tool, color, replacement) {
    const normalized = replacement.toUpperCase()
    const presets = colorPresets(tool)
    if (presets.includes(color) && !presets.includes(normalized)) {
        write(`${tool}Presets`, presets.map((candidate) => (candidate === color ? normalized : candidate)))
    }
}

export function inkSmoothing() {
    return clamp(readSetting("inkSmoothing", tokens.ink.smoothing_points), tokens.ink.smoothing_range)
}

export function setInkSmoothing(value) {
    write("inkSmoothing", clamp(value, tokens.ink.smoothing_range))
}

export function eraserRadius() {
    return clamp(readSetting("eraserRadius", tokens.tools.eraser.radius), tokens.tools.eraser.radius_range)
}

export function setEraserRadius(radius) {
    write("eraserRadius", clamp(radius, tokens.tools.eraser.radius_range))
}

export function eraserMode() {
    const mode = readSetting("eraserMode", tokens.tools.eraser.modes[0])
    return tokens.tools.eraser.modes.includes(mode) ? mode : tokens.tools.eraser.modes[0]
}

export function setEraserMode(mode) {
    write("eraserMode", mode)
}

export function textFontSize() {
    return clamp(readSetting("textFontSize", tokens.text.font_size), tokens.text.font_size_range)
}

export function setTextFontSize(size) {
    write("textFontSize", clamp(size, tokens.text.font_size_range))
}

export function toolOrder() {
    const stored = readSetting("toolOrder", [])
    const known = Array.isArray(stored) ? stored.filter((tool) => allTools.includes(tool)) : []
    return [...known, ...allTools.filter((tool) => !known.includes(tool))]
}

export function setToolOrder(order) {
    write("toolOrder", order)
}

export function subNavigationOrder(key) {
    const stored = readSetting(`subNavigationOrder.${key}`, [])
    return Array.isArray(stored) ? stored : []
}

export function setSubNavigationOrder(order, key) {
    write(`subNavigationOrder.${key}`, order)
}

export function groups(parentId) {
    const stored = readSetting(`groups.${parentId ?? "root"}`, [])
    return Array.isArray(stored) ? stored : []
}

function setGroups(list, parentId) {
    write(`groups.${parentId ?? "root"}`, list.filter((group) => group.members.length > 0))
}

function withoutMember(memberId, parentId) {
    return groups(parentId).map((group) => ({ ...group, members: group.members.filter((member) => member !== memberId) }))
}

export function groupOf(memberId, parentId) {
    return groups(parentId).find((group) => group.members.includes(memberId)) ?? null
}

export function addToGroup(memberId, groupId, parentId) {
    const list = withoutMember(memberId, parentId)
    const group = list.find((candidate) => candidate.id === groupId)
    if (!group) {
        return
    }
    group.members.push(memberId)
    setGroups(list, parentId)
}

export function createGroup(title, isFolders, memberId, parentId) {
    const list = withoutMember(memberId, parentId)
    list.push({ id: crypto.randomUUID().toUpperCase(), title, isFolders, members: [memberId] })
    setGroups(list, parentId)
}

export function removeFromGroup(memberId, parentId) {
    setGroups(withoutMember(memberId, parentId), parentId)
}

export function renameGroup(groupId, title, parentId) {
    setGroups(groups(parentId).map((group) => (group.id === groupId ? { ...group, title } : group)), parentId)
}

export function ungroup(groupId, parentId) {
    setGroups(groups(parentId).filter((group) => group.id !== groupId), parentId)
}

export function navPlacement() {
    return readSetting("navPlacement", null)
}

export function setNavPlacement(placement) {
    writeSetting("navPlacement", placement)
}
