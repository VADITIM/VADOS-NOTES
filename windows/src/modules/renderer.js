import { cellCount, cellHeight, cellWidth, liveElements, paperHeight, paperWidth } from "./model.js"
import { tokens, withAlpha } from "./tokens.js"

export const monoFamily = "\"Space Mono\""
export const minimumScale = 0.6
export const maximumScale = 40
const layoutScale = 10
const minimumTextHeightPerFontSize = 1.4

export class Camera {
    constructor(scale = 3, offsetX = 0, offsetY = 0) {
        this.scale = scale
        this.offsetX = offsetX
        this.offsetY = offsetY
    }

    toScreen(point) {
        return [point[0] * this.scale + this.offsetX, point[1] * this.scale + this.offsetY]
    }

    toPage(x, y) {
        return [(x - this.offsetX) / this.scale, (y - this.offsetY) / this.scale]
    }

    zoomed(factor, anchorX, anchorY) {
        const scale = Math.min(maximumScale, Math.max(minimumScale, this.scale * factor))
        const pagePoint = this.toPage(anchorX, anchorY)
        return new Camera(scale, anchorX - pagePoint[0] * scale, anchorY - pagePoint[1] * scale)
    }

    static fitting(extent, width, height, margin) {
        const availableWidth = Math.max(1, width - margin * 2)
        const availableHeight = Math.max(1, height - margin * 2)
        const scale = Math.min(availableWidth / cellWidth, availableHeight / cellHeight)
        const shownWidth = extent.cols * cellWidth * scale
        const horizontalOffset = shownWidth < width ? (width - shownWidth) / 2 : margin
        return new Camera(scale, horizontalOffset, margin)
    }
}

export function inkColor(element) {
    const base = element.color ?? "#1A1A1A"
    const tool = element.tool ? tokens.tools[element.tool] : null
    return tool ? withAlpha(base, tool.opacity) : base
}

export function strokePath(points, transform = (point) => point) {
    const path = new Path2D()
    if (!points.length) {
        return path
    }
    const first = transform(points[0])
    path.moveTo(first[0], first[1])
    if (points.length === 1) {
        path.lineTo(first[0], first[1])
        return path
    }
    if (points.length === 2) {
        const second = transform(points[1])
        path.lineTo(second[0], second[1])
        return path
    }
    for (let index = 1; index < points.length - 1; index += 1) {
        const control = transform(points[index])
        const next = transform(points[index + 1])
        path.quadraticCurveTo(control[0], control[1], (control[0] + next[0]) / 2, (control[1] + next[1]) / 2)
    }
    const last = transform(points[points.length - 1])
    path.lineTo(last[0], last[1])
    return path
}

export class StrokePathCache {
    constructor() {
        this.entries = new Map()
    }

    path(element) {
        const entry = this.entries.get(element.id)
        if (entry && entry.updated === element.updated) {
            return entry
        }
        const points = element.points ?? []
        const inset = element.width ?? 1
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
        const created = {
            updated: element.updated,
            path: strokePath(points),
            bounds: { minimumX: minimumX - inset, minimumY: minimumY - inset, maximumX: maximumX + inset, maximumY: maximumY + inset },
        }
        this.entries.set(element.id, created)
        return created
    }
}

const measuringContext = document.createElement("canvas").getContext("2d")
const layoutCache = new Map()

export function fontMetrics(fontSizePixels) {
    measuringContext.font = `${fontSizePixels}px ${monoFamily}`
    const metrics = measuringContext.measureText("Hg")
    const ascent = metrics.fontBoundingBoxAscent ?? fontSizePixels * 1.12
    const descent = metrics.fontBoundingBoxDescent ?? fontSizePixels * 0.36
    return { ascent, descent, lineHeight: (ascent + descent) * tokens.text.line_height }
}

function wrap(content, fontSizePixels, widthPixels) {
    measuringContext.font = `${fontSizePixels}px ${monoFamily}`
    const lines = []
    for (const paragraph of content.split("\n")) {
        const words = paragraph.split(/(\s+)/)
        let line = ""
        for (const word of words) {
            const candidate = line + word
            if (measuringContext.measureText(candidate.trimEnd()).width <= widthPixels || line.length === 0) {
                if (line.length === 0 && measuringContext.measureText(word).width > widthPixels) {
                    let piece = ""
                    for (const character of word) {
                        if (measuringContext.measureText(piece + character).width > widthPixels && piece.length) {
                            lines.push(piece)
                            piece = ""
                        }
                        piece += character
                    }
                    line = piece
                } else {
                    line = candidate
                }
            } else {
                lines.push(line.trimEnd())
                line = /^\s+$/.test(word) ? "" : word
            }
        }
        lines.push(line.trimEnd())
    }
    return lines
}

export function textLayout(element) {
    const fontSize = element.font_size ?? tokens.text.font_size
    const width = element.box?.width ?? tokens.text.box_width
    const content = element.content ?? ""
    const key = `${fontSize}|${width}|${content}`
    const cached = layoutCache.get(key)
    if (cached) {
        return cached
    }
    const metrics = fontMetrics(fontSize * layoutScale)
    const lines = content.length ? wrap(content, fontSize * layoutScale, width * layoutScale) : []
    const layout = {
        lines,
        fontSize,
        lineHeight: metrics.lineHeight / layoutScale,
        descent: metrics.descent / layoutScale,
        height: (lines.length * metrics.lineHeight) / layoutScale,
    }
    if (layoutCache.size > 2000) {
        layoutCache.clear()
    }
    layoutCache.set(key, layout)
    return layout
}

export function textRect(element) {
    if (element.type !== "text" || !element.box) {
        return null
    }
    const layout = textLayout(element)
    return {
        x: element.box.x,
        y: element.box.y,
        width: element.box.width,
        height: Math.max(layout.height, (element.font_size ?? tokens.text.font_size) * minimumTextHeightPerFontSize),
    }
}

function drawGuides(context, visible, camera) {
    const spacing = tokens.page.grid_spacing
    if (spacing * camera.scale < 4) {
        return
    }
    context.save()
    context.strokeStyle = tokens.page.guide
    context.lineWidth = 1 / camera.scale
    context.beginPath()
    for (let x = Math.floor(visible.minimumX / spacing) * spacing; x <= visible.maximumX; x += spacing) {
        context.moveTo(x, visible.minimumY)
        context.lineTo(x, visible.maximumY)
    }
    for (let y = Math.floor(visible.minimumY / spacing) * spacing; y <= visible.maximumY; y += spacing) {
        context.moveTo(visible.minimumX, y)
        context.lineTo(visible.maximumX, y)
    }
    context.stroke()
    context.restore()
}

function drawCellBoundaries(context, extent, camera) {
    if (cellCount(extent) <= 1) {
        return
    }
    context.save()
    context.strokeStyle = tokens.page.cell_boundary
    context.lineWidth = 1.5 / camera.scale
    context.setLineDash([6 / camera.scale, 4 / camera.scale])
    context.beginPath()
    for (let column = 1; column < extent.cols; column += 1) {
        context.moveTo(column * cellWidth, 0)
        context.lineTo(column * cellWidth, extent.rows * cellHeight)
    }
    for (let row = 1; row < extent.rows; row += 1) {
        context.moveTo(0, row * cellHeight)
        context.lineTo(extent.cols * cellWidth, row * cellHeight)
    }
    context.stroke()
    context.restore()
}

function drawStroke(context, element, visible, cache) {
    const cached = cache.path(element)
    const bounds = cached.bounds
    if (bounds.maximumX < visible.minimumX || bounds.minimumX > visible.maximumX || bounds.maximumY < visible.minimumY || bounds.minimumY > visible.maximumY) {
        return
    }
    context.lineWidth = element.width ?? 0.5
    context.lineCap = "round"
    context.lineJoin = "round"
    context.strokeStyle = inkColor(element)
    context.stroke(cached.path)
}

function drawText(context, element, camera, offset, pixelRatio) {
    if (!element.content || !element.box) {
        return
    }
    const layout = textLayout(element)
    const scale = camera.scale * pixelRatio
    const fontPixels = layout.fontSize * scale
    context.save()
    context.setTransform(1, 0, 0, 1, 0, 0)
    context.font = `${fontPixels}px ${monoFamily}`
    context.fillStyle = element.color ?? tokens.text.color
    context.textBaseline = "alphabetic"
    const left = ((element.box.x + offset[0]) * camera.scale + camera.offsetX) * pixelRatio
    const top = ((element.box.y + offset[1]) * camera.scale + camera.offsetY) * pixelRatio
    layout.lines.forEach((line, index) => {
        const baseline = top + ((index + 1) * layout.lineHeight - layout.descent) * scale
        context.fillText(line, left, baseline)
    })
    context.restore()
}

export function drawPage(context, page, camera, { width, height, pixelRatio = 1, showsGuides = true, hiddenElementIds = new Set(), textOffsets = new Map(), cache }) {
    context.setTransform(pixelRatio, 0, 0, pixelRatio, 0, 0)
    context.fillStyle = tokens.page.outside
    context.fillRect(0, 0, width, height)

    const paper = { minimumX: 0, minimumY: 0, maximumX: paperWidth(page.extent), maximumY: paperHeight(page.extent) }
    const topLeft = camera.toPage(0, 0)
    const bottomRight = camera.toPage(width, height)
    const visible = {
        minimumX: Math.max(paper.minimumX, topLeft[0]),
        minimumY: Math.max(paper.minimumY, topLeft[1]),
        maximumX: Math.min(paper.maximumX, bottomRight[0]),
        maximumY: Math.min(paper.maximumY, bottomRight[1]),
    }
    if (visible.minimumX > visible.maximumX || visible.minimumY > visible.maximumY) {
        return
    }

    context.save()
    context.translate(camera.offsetX, camera.offsetY)
    context.scale(camera.scale, camera.scale)
    context.fillStyle = tokens.page.paper
    context.fillRect(0, 0, paper.maximumX, paper.maximumY)
    if (showsGuides) {
        drawGuides(context, visible, camera)
    }
    drawCellBoundaries(context, page.extent, camera)
    context.beginPath()
    context.rect(0, 0, paper.maximumX, paper.maximumY)
    context.clip()
    for (const element of liveElements(page)) {
        if (hiddenElementIds.has(element.id)) {
            continue
        }
        if (element.type === "stroke") {
            drawStroke(context, element, visible, cache)
        } else if (element.type === "text") {
            drawText(context, element, camera, textOffsets.get(element.id) ?? [0, 0], pixelRatio)
        }
    }
    context.restore()
}

export function renderThumbnail(canvas, page, showsGuides) {
    const width = canvas.clientWidth
    const height = canvas.clientHeight
    if (width === 0 || height === 0) {
        return
    }
    const pixelRatio = window.devicePixelRatio || 1
    canvas.width = Math.round(width * pixelRatio)
    canvas.height = Math.round(height * pixelRatio)
    const pageWidth = paperWidth(page.extent)
    const pageHeight = paperHeight(page.extent)
    const scale = Math.min(width / pageWidth, height / pageHeight)
    const camera = new Camera(scale, (width - pageWidth * scale) / 2, (height - pageHeight * scale) / 2)
    const context = canvas.getContext("2d")
    drawPage(context, page, camera, { width, height, pixelRatio, showsGuides, cache: new StrokePathCache() })
}
