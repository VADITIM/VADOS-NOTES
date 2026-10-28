import { cellCount, cellHeight, cellWidth, liveElements, paperHeight, paperWidth, scaledElement, translatedElement } from "./model.js"
import { importImage } from "./imports.js"
import { markdownBlocks } from "./markdown.js"
import { inkOnPaper, paperColors, tokens, withAlpha } from "./tokens.js"

export const monoFamily = "\"Space Mono\""
export const minimumScale = 0.01
export const maximumScale = 40
export const panSlackShare = 0.45
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

    static smallestScale(extent, width, height, margin, topInset) {
        const availableWidth = Math.max(1, width - margin * 2)
        const availableHeight = Math.max(1, height - (topInset + margin) * 2)
        return Math.min(maximumScale, Math.min(availableWidth / paperWidth(extent), availableHeight / paperHeight(extent)))
    }

    static fitting(extent, width, height, margin, topInset = 0) {
        const scale = Camera.smallestScale(extent, width, height, margin, topInset)
        return new Camera(scale, (width - paperWidth(extent) * scale) / 2, (height - paperHeight(extent) * scale) / 2)
    }

    constrained(extent, width, height, margin, topInset) {
        const smallest = Camera.smallestScale(extent, width, height, margin, topInset)
        let camera = new Camera(this.scale, this.offsetX, this.offsetY)
        if (camera.scale < smallest) {
            camera = camera.zoomed(smallest / camera.scale, width / 2, height / 2)
        }
        const axis = (offset, size, start, end, slack) => {
            if (size <= end - start) {
                const centred = start + (end - start - size) / 2
                return Math.min(centred + slack, Math.max(centred - slack, offset))
            }
            return Math.min(start + slack, Math.max(end - size - slack, offset))
        }
        camera.offsetX = axis(camera.offsetX, paperWidth(extent) * camera.scale, margin, width - margin, width * panSlackShare)
        camera.offsetY = axis(camera.offsetY, paperHeight(extent) * camera.scale, margin, height - margin, height * panSlackShare)
        return camera
    }
}

export function inkColor(element, style) {
    const base = inkOnPaper(element.color ?? "#1A1A1A", style)
    const tool = element.tool ? tokens.tools[element.tool] : null
    return tool ? withAlpha(base, tool.opacity) : base
}

const minimumSpan = 1e-4

function span(first, second) {
    return Math.max(minimumSpan, Math.sqrt(Math.hypot(second[0] - first[0], second[1] - first[1])))
}

function splineControls(before, start, end, after) {
    const leading = span(before, start)
    const middle = span(start, end)
    const trailing = span(end, after)
    const leadingWeight = 2 * leading * leading + 3 * leading * middle + middle * middle
    const trailingWeight = 2 * trailing * trailing + 3 * trailing * middle + middle * middle
    const leadingDivisor = 3 * leading * (leading + middle)
    const trailingDivisor = 3 * trailing * (trailing + middle)
    return [
        [0, 1].map((axis) => (leading * leading * end[axis] - middle * middle * before[axis] + leadingWeight * start[axis]) / leadingDivisor),
        [0, 1].map((axis) => (trailing * trailing * start[axis] - middle * middle * after[axis] + trailingWeight * end[axis]) / trailingDivisor),
    ]
}

export function strokePath(points, transform = (point) => point) {
    const path = new Path2D()
    if (!points.length) {
        return path
    }
    const shown = points.map(transform)
    path.moveTo(shown[0][0], shown[0][1])
    if (shown.length === 1) {
        path.lineTo(shown[0][0], shown[0][1])
        return path
    }
    if (shown.length === 2) {
        path.lineTo(shown[1][0], shown[1][1])
        return path
    }
    const last = shown.length - 1
    for (let index = 0; index < last; index += 1) {
        const start = shown[index]
        const end = shown[index + 1]
        const before = index > 0 ? shown[index - 1] : [start[0] * 2 - end[0], start[1] * 2 - end[1]]
        const after = index + 2 <= last ? shown[index + 2] : [end[0] * 2 - start[0], end[1] * 2 - start[1]]
        const [first, second] = splineControls(before, start, end, after)
        path.bezierCurveTo(first[0], first[1], second[0], second[1], end[0], end[1])
    }
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

const indentCharacters = 3
const markerGapCharacters = 1

function runFont(style, sizePixels) {
    return `${style.isItalic ? "italic " : ""}${style.isBold ? "700" : "400"} ${sizePixels}px ${monoFamily}`
}

function measure(text, style, sizePixels) {
    measuringContext.font = runFont(style, sizePixels)
    return measuringContext.measureText(text).width
}

const plainRunStyle = { isBold: false, isItalic: false, isCode: false, isStruck: false, isLink: false }

function wrapRuns(runs, sizePixels, startX, widthPixels) {
    const lines = [[]]
    let x = startX
    const place = (text, style) => {
        const width = measure(text, style, sizePixels)
        const line = lines[lines.length - 1]
        const last = line[line.length - 1]
        if (last && last.style === style && last.x + last.width === x) {
            last.text += text
            last.width += width
        } else {
            line.push({ text, style, x, width })
        }
        x += width
    }
    const newLine = () => {
        const line = lines[lines.length - 1]
        while (line.length && /^\s+$/.test(line[line.length - 1].text)) {
            line.pop()
        }
        lines.push([])
        x = startX
    }
    for (const run of runs) {
        for (const piece of run.text.split(/(\s+)/)) {
            if (!piece) {
                continue
            }
            const isSpace = /^\s+$/.test(piece)
            const width = measure(piece, run.style, sizePixels)
            const isLineEmpty = lines[lines.length - 1].length === 0
            if (isSpace && isLineEmpty) {
                continue
            }
            if (x + width <= startX + widthPixels || isSpace) {
                place(piece, run.style)
                continue
            }
            if (!isLineEmpty) {
                newLine()
            }
            if (width <= widthPixels) {
                place(piece, run.style)
                continue
            }
            let chunk = ""
            for (const character of piece) {
                if (chunk && x + measure(chunk + character, run.style, sizePixels) > startX + widthPixels) {
                    place(chunk, run.style)
                    newLine()
                    chunk = ""
                }
                chunk += character
            }
            place(chunk, run.style)
        }
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
    const lines = []
    let top = 0
    const widthPixels = width * layoutScale
    const blocks = content.length ? markdownBlocks(content) : []
    for (const block of blocks) {
        const sizePixels = fontSize * block.scale * layoutScale
        const metrics = fontMetrics(sizePixels)
        const characterWidth = measure("0", plainRunStyle, sizePixels)
        const startX = block.indent * indentCharacters * characterWidth
        const wrapped = block.kind === "rule" ? [[]] : wrapRuns(block.runs, sizePixels, startX, Math.max(characterWidth, widthPixels - startX))
        wrapped.forEach((segments, index) => {
            lines.push({
                top: top / layoutScale,
                height: metrics.lineHeight / layoutScale,
                descent: metrics.descent / layoutScale,
                fontSize: fontSize * block.scale,
                kind: block.kind,
                isFirst: index === 0,
                isChecked: Boolean(block.isChecked),
                marker: index === 0 && block.marker ? { text: block.marker, x: (startX - (block.marker.length + markerGapCharacters) * characterWidth) / layoutScale } : null,
                quoteX: block.kind === "quote" ? (characterWidth * 0.8) / layoutScale : null,
                segments: segments.map((segment) => ({ text: segment.text, style: segment.style, x: segment.x / layoutScale, width: segment.width / layoutScale })),
            })
            top += metrics.lineHeight
        })
    }
    const layout = { lines, fontSize, height: top / layoutScale }
    if (layoutCache.size > 2000) {
        layoutCache.clear()
    }
    layoutCache.set(key, layout)
    return layout
}

export function lineHeightOf(fontSize) {
    return fontMetrics(fontSize * layoutScale).lineHeight / layoutScale
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

function drawGuides(context, visible, camera, colors) {
    const spacing = tokens.page.grid_spacing
    if (spacing * camera.scale < 4) {
        return
    }
    context.save()
    context.strokeStyle = colors.guide
    context.lineWidth = 1 / camera.scale
    context.beginPath()
    for (let x = Math.floor(visible.minimumX / spacing) * spacing; x <= visible.maximumX; x += spacing) {
        context.moveTo(x, visible.minimumY)
        context.lineTo(x, visible.maximumY)
    }
    const rowSpacing = cellHeight / Math.max(1, Math.round(cellHeight / spacing))
    for (let row = Math.floor(visible.minimumY / rowSpacing); row * rowSpacing <= visible.maximumY; row += 1) {
        context.moveTo(visible.minimumX, row * rowSpacing)
        context.lineTo(visible.maximumX, row * rowSpacing)
    }
    context.stroke()
    context.restore()
}

function drawCellBoundaries(context, extent, camera, colors) {
    if (cellCount(extent) <= 1) {
        return
    }
    context.save()
    context.strokeStyle = colors.cell_boundary
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

function drawStroke(context, element, visible, cache, style) {
    const cached = cache.path(element)
    const bounds = cached.bounds
    if (bounds.maximumX < visible.minimumX || bounds.minimumX > visible.maximumX || bounds.maximumY < visible.minimumY || bounds.minimumY > visible.maximumY) {
        return
    }
    context.lineWidth = element.width ?? 0.5
    context.lineCap = "round"
    context.lineJoin = "round"
    context.strokeStyle = inkColor(element, style)
    context.stroke(cached.path)
}

function drawText(context, element, camera, pixelRatio, style) {
    if (!element.content || !element.box) {
        return
    }
    const layout = textLayout(element)
    const scale = camera.scale * pixelRatio
    const color = inkOnPaper(element.color ?? tokens.text.color, style)
    const faint = withAlpha(color, 0.14)
    const left = (element.box.x * camera.scale + camera.offsetX) * pixelRatio
    const top = (element.box.y * camera.scale + camera.offsetY) * pixelRatio
    const boxWidth = element.box.width * scale
    context.save()
    context.setTransform(1, 0, 0, 1, 0, 0)
    context.textBaseline = "alphabetic"
    for (const line of layout.lines) {
        const lineTop = top + line.top * scale
        const lineHeight = line.height * scale
        const baseline = top + (line.top + line.height - line.descent) * scale
        const sizePixels = line.fontSize * scale
        context.globalAlpha = line.isChecked ? 0.55 : 1
        if (line.kind === "code") {
            context.fillStyle = faint
            context.fillRect(left, lineTop, boxWidth, lineHeight)
        }
        if (line.kind === "rule") {
            context.fillStyle = withAlpha(color, 0.45)
            context.fillRect(left, lineTop + lineHeight / 2 - Math.max(1, scale * 0.15) / 2, boxWidth, Math.max(1, scale * 0.15))
        }
        if (line.quoteX !== null) {
            context.fillStyle = withAlpha(color, 0.5)
            context.fillRect(left + line.quoteX * scale, lineTop, Math.max(1, sizePixels * 0.12), lineHeight)
        }
        if (line.marker) {
            context.font = runFont({ isBold: true }, sizePixels)
            context.fillStyle = color
            context.fillText(line.marker.text, left + line.marker.x * scale, baseline)
        }
        for (const segment of line.segments) {
            const x = left + segment.x * scale
            const width = segment.width * scale
            if (segment.style.isCode && line.kind !== "code") {
                context.fillStyle = faint
                context.fillRect(x, lineTop + lineHeight * 0.08, width, lineHeight * 0.84)
            }
            context.font = runFont(segment.style, sizePixels)
            context.fillStyle = color
            context.fillText(segment.text, x, baseline)
            const thickness = Math.max(1, sizePixels * 0.07)
            if (segment.style.isStruck) {
                context.fillRect(x, baseline - sizePixels * 0.3, width, thickness)
            }
            if (segment.style.isLink) {
                context.fillRect(x, baseline + sizePixels * 0.14, width, thickness)
            }
        }
    }
    context.restore()
}

export function importRect(element) {
    if (!element.source_size_mm || !element.placement) {
        return null
    }
    const scale = element.placement.scale ?? 1
    return { x: element.placement.x, y: element.placement.y, width: element.source_size_mm[0] * scale, height: element.source_size_mm[1] * scale }
}

function drawImport(context, element, camera, pixelRatio, paperStyle, colors, visible) {
    const rect = importRect(element)
    if (!rect) {
        return
    }
    if (visible && (rect.x > visible.maximumX || rect.x + rect.width < visible.minimumX || rect.y > visible.maximumY || rect.y + rect.height < visible.minimumY)) {
        return
    }
    const image = importImage(element, camera.scale * pixelRatio, paperStyle === "dark")
    if (!image) {
        context.fillStyle = colors.guide
        context.fillRect(rect.x, rect.y, rect.width, rect.height)
        return
    }
    context.imageSmoothingEnabled = true
    context.imageSmoothingQuality = "medium"
    context.drawImage(image, rect.x, rect.y, rect.width, rect.height)
}

export function clipToPaper(context, extent) {
    context.beginPath()
    context.roundRect(0, 0, paperWidth(extent), paperHeight(extent), tokens.page.corner_radius)
    context.clip()
}

export function drawPage(context, page, camera, { width, height, pixelRatio = 1, showsGuides = true, showsDividers = true, paperStyle, hiddenElementIds = new Set(), elementOffsets = new Map(), elementScale = null, fillsOutside = true, cache }) {
    const colors = paperColors(paperStyle)
    context.setTransform(pixelRatio, 0, 0, pixelRatio, 0, 0)
    if (fillsOutside) {
        context.fillStyle = tokens.page.outside
        context.fillRect(0, 0, width, height)
    } else {
        context.clearRect(0, 0, width, height)
    }

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
    const everywhere = { minimumX: -Infinity, minimumY: -Infinity, maximumX: Infinity, maximumY: Infinity }

    context.save()
    context.translate(camera.offsetX, camera.offsetY)
    context.scale(camera.scale, camera.scale)
    clipToPaper(context, page.extent)
    context.fillStyle = colors.paper
    context.fillRect(0, 0, paper.maximumX, paper.maximumY)
    if (showsGuides) {
        drawGuides(context, visible, camera, colors)
    }
    if (showsDividers) {
        drawCellBoundaries(context, page.extent, camera, colors)
    }
    for (const element of liveElements(page)) {
        if (hiddenElementIds.has(element.id)) {
            continue
        }
        const offset = elementOffsets.get(element.id)
        const scale = elementScale?.ids.has(element.id) ? elementScale : null
        if (element.type === "text") {
            let shown = scale ? scaledElement(element, scale.anchor, scale.factor) : element
            shown = offset ? translatedElement(shown, offset) : shown
            drawText(context, shown, camera, pixelRatio, paperStyle)
            continue
        }
        context.save()
        if (offset) {
            context.translate(offset[0], offset[1])
        }
        if (scale) {
            context.translate(scale.anchor[0], scale.anchor[1])
            context.scale(scale.factor, scale.factor)
            context.translate(-scale.anchor[0], -scale.anchor[1])
        }
        const isMoved = Boolean(offset || scale)
        if (element.type === "import") {
            drawImport(context, element, camera, pixelRatio, paperStyle, colors, isMoved ? null : visible)
        } else if (element.type === "stroke") {
            drawStroke(context, element, isMoved ? everywhere : visible, cache, paperStyle)
        }
        context.restore()
    }
    context.restore()
}

export function renderThumbnail(canvas, page, { showsGuides, showsDividers, paperStyle }) {
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
    drawPage(context, page, camera, { width, height, pixelRatio, showsGuides, showsDividers, paperStyle, cache: new StrokePathCache() })
}
