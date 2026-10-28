import { tokens } from "./tokens.js"

export const schemaVersion = 1
export const cellWidth = 210
export const cellHeight = 297
export const pointPrecision = 100

const identifierAlphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
const identifierTimeCharacters = 10
const identifierRandomCharacters = 16
const layerRanks = { import: 1, marker: 2, ink: 3, text: 4, overlay: 5 }

export function makeIdentifier(prefix, milliseconds) {
    let characters = ""
    let remaining = BigInt(Math.max(0, Math.floor(milliseconds)))
    const timeCharacters = []
    for (let position = 0; position < identifierTimeCharacters; position += 1) {
        timeCharacters.unshift(identifierAlphabet[Number(remaining & 31n)])
        remaining >>= 5n
    }
    characters += timeCharacters.join("")
    const random = new Uint8Array(identifierRandomCharacters)
    crypto.getRandomValues(random)
    for (const value of random) {
        characters += identifierAlphabet[value & 31]
    }
    return `${prefix}_${characters}`
}

export function creationDate(identifier) {
    const separator = identifier.indexOf("_")
    const characters = identifier.slice(separator + 1, separator + 1 + identifierTimeCharacters)
    if (separator < 0 || characters.length !== identifierTimeCharacters) {
        return null
    }
    let milliseconds = 0
    for (const character of characters) {
        const value = identifierAlphabet.indexOf(character)
        if (value < 0) {
            return null
        }
        milliseconds = milliseconds * 32 + value
    }
    return new Date(milliseconds)
}

export function timestampNow() {
    return new Date().toISOString()
}

export function timestampMilliseconds(text) {
    return Date.parse(text)
}

export function layerForTool(tool) {
    return tool === "marker" ? "marker" : "ink"
}

export function isOrderedBefore(first, second) {
    const firstRank = layerRanks[first.layer] ?? 0
    const secondRank = layerRanks[second.layer] ?? 0
    if (firstRank !== secondRank) {
        return firstRank < secondRank
    }
    if (first.order !== second.order) {
        return first.order < second.order
    }
    return first.id < second.id
}

export function compareElements(first, second) {
    if (first.id === second.id) {
        return 0
    }
    return isOrderedBefore(first, second) ? -1 : 1
}

export function liveElements(page) {
    return page.elements.filter((element) => !element.deleted).sort(compareElements)
}

export function nextOrder(page, layer) {
    const orders = page.elements.filter((element) => element.layer === layer).map((element) => element.order)
    return (orders.length ? Math.max(...orders) : -1) + 1
}

export function cellCount(extent) {
    return extent.cols * extent.rows
}

export function paperWidth(extent) {
    return extent.cols * cellWidth
}

export function paperHeight(extent) {
    return extent.rows * cellHeight
}

export function roundedPoint(point) {
    return [Math.round(point[0] * pointPrecision) / pointPrecision, Math.round(point[1] * pointPrecision) / pointPrecision]
}

export function distance(first, second) {
    return Math.hypot(first[0] - second[0], first[1] - second[1])
}

function distanceToSegment(point, start, end) {
    const segmentX = end[0] - start[0]
    const segmentY = end[1] - start[1]
    const lengthSquared = segmentX * segmentX + segmentY * segmentY
    if (lengthSquared <= 0) {
        return distance(point, start)
    }
    const projection = ((point[0] - start[0]) * segmentX + (point[1] - start[1]) * segmentY) / lengthSquared
    const clamped = Math.min(1, Math.max(0, projection))
    return distance(point, [start[0] + clamped * segmentX, start[1] + clamped * segmentY])
}

function pointAt(start, end, share) {
    return [start[0] + (end[0] - start[0]) * share, start[1] + (end[1] - start[1]) * share]
}

function strokeLength(points) {
    let length = 0
    for (let index = 1; index < points.length; index += 1) {
        length += distance(points[index - 1], points[index])
    }
    return length
}

function evenlySpaced(points, spacing) {
    if (points.length < 2) {
        return points.map((point) => [...point])
    }
    const result = [[...points[0]]]
    let carried = 0
    for (let index = 1; index < points.length; index += 1) {
        const start = points[index - 1]
        const end = points[index]
        const length = distance(start, end)
        let travelled = spacing - carried
        while (travelled <= length) {
            result.push(pointAt(start, end, travelled / length))
            travelled += spacing
        }
        carried = length - (travelled - spacing)
    }
    const last = points[points.length - 1]
    if (distance(result[result.length - 1], last) > spacing * 0.05) {
        result.push([...last])
    } else {
        result[result.length - 1] = [...last]
    }
    return result
}

function gaussianSmoothed(points, sigmaSamples) {
    if (points.length < 3 || sigmaSamples <= 0) {
        return points
    }
    const reachSamples = Math.ceil(sigmaSamples * 2.5)
    const weights = []
    for (let offset = 0; offset <= reachSamples; offset += 1) {
        weights.push(Math.exp(-(offset * offset) / (2 * sigmaSamples * sigmaSamples)))
    }
    const last = points.length - 1
    return points.map((point, index) => {
        const window = Math.min(reachSamples, index, last - index)
        if (window === 0) {
            return point
        }
        let x = point[0] * weights[0]
        let y = point[1] * weights[0]
        let total = weights[0]
        for (let offset = 1; offset <= window; offset += 1) {
            const weight = weights[offset]
            x += (points[index - offset][0] + points[index + offset][0]) * weight
            y += (points[index - offset][1] + points[index + offset][1]) * weight
            total += weight * 2
        }
        return [x / total, y / total]
    })
}

function simplified(points, tolerance) {
    if (points.length < 3) {
        return points
    }
    const keep = new Uint8Array(points.length)
    keep[0] = 1
    keep[points.length - 1] = 1
    const ranges = [[0, points.length - 1]]
    while (ranges.length) {
        const [first, last] = ranges.pop()
        let farthest = -1
        let farthestDistance = tolerance
        for (let index = first + 1; index < last; index += 1) {
            const candidate = distanceToSegment(points[index], points[first], points[last])
            if (candidate > farthestDistance) {
                farthest = index
                farthestDistance = candidate
            }
        }
        if (farthest >= 0) {
            keep[farthest] = 1
            ranges.push([first, farthest], [farthest, last])
        }
    }
    return points.filter((point, index) => keep[index])
}

function cleaned(points) {
    const rounded = []
    for (const point of points) {
        const next = roundedPoint(point)
        const previous = rounded[rounded.length - 1]
        if (!previous || previous[0] !== next[0] || previous[1] !== next[1]) {
            rounded.push(next)
        }
    }
    return rounded
}

export function smoothStroke(points, scale, smoothing = tokens.ink.smoothing_points) {
    if (points.length < 3) {
        return cleaned(points)
    }
    const spacing = tokens.ink.sample_spacing_points / scale
    const even = evenlySpaced(points, spacing)
    const smooth = gaussianSmoothed(even, smoothing / tokens.ink.sample_spacing_points)
    return cleaned(simplified(smooth, tokens.ink.simplify_points / scale))
}

export function axisSnapped(start, end) {
    const deltaX = end[0] - start[0]
    const deltaY = end[1] - start[1]
    const tolerance = Math.tan((tokens.ink.straighten_axis_snap_degrees * Math.PI) / 180)
    if (Math.abs(deltaY) <= Math.abs(deltaX) * tolerance) {
        return [end[0], start[1]]
    }
    if (Math.abs(deltaX) <= Math.abs(deltaY) * tolerance) {
        return [start[0], end[1]]
    }
    return end
}

function isInsideRect(point, width, height) {
    return point[0] >= 0 && point[0] <= width && point[1] >= 0 && point[1] <= height
}

function insideShares(start, end, width, height) {
    let entry = 0
    let exit = 1
    const deltaX = end[0] - start[0]
    const deltaY = end[1] - start[1]
    const limits = [[-deltaX, start[0]], [deltaX, width - start[0]], [-deltaY, start[1]], [deltaY, height - start[1]]]
    for (const [direction, room] of limits) {
        if (direction === 0) {
            if (room < 0) {
                return null
            }
            continue
        }
        const share = room / direction
        if (direction < 0) {
            entry = Math.max(entry, share)
        } else {
            exit = Math.min(exit, share)
        }
        if (entry > exit) {
            return null
        }
    }
    return [entry, exit]
}

export function clipToPaper(points, extent) {
    const width = paperWidth(extent)
    const height = paperHeight(extent)
    if (points.every((point) => isInsideRect(point, width, height))) {
        return [points]
    }
    if (points.length === 1) {
        return []
    }
    const pieces = []
    let current = []
    for (let index = 1; index < points.length; index += 1) {
        const start = points[index - 1]
        const end = points[index]
        const shares = insideShares(start, end, width, height)
        if (!shares) {
            if (current.length) {
                pieces.push(current)
                current = []
            }
            continue
        }
        const [entry, exit] = shares
        if (!current.length) {
            current.push(pointAt(start, end, entry))
        }
        current.push(pointAt(start, end, exit))
        if (exit < 1) {
            pieces.push(current)
            current = []
        }
    }
    if (current.length) {
        pieces.push(current)
    }
    return pieces.map(cleaned).filter((piece) => piece.length >= 2)
}

export function clampBox(box, extent, height) {
    const width = Math.min(box.width, paperWidth(extent))
    return {
        ...box,
        width,
        x: Math.min(paperWidth(extent) - width, Math.max(0, box.x)),
        y: Math.min(paperHeight(extent) - height, Math.max(0, box.y)),
    }
}

export function isInsidePaper(point, extent) {
    return isInsideRect(point, paperWidth(extent), paperHeight(extent))
}

export function sortedByOrder(items) {
    const byIdentifier = [...items].sort((first, second) => (first.id < second.id ? -1 : 1))
    const rank = new Map(byIdentifier.map((item, index) => [item.id, Number.isFinite(item.order) ? item.order : index]))
    return byIdentifier.sort((first, second) => rank.get(first.id) - rank.get(second.id) || (first.id < second.id ? -1 : 1))
}

export function straightened(points, start, end, share) {
    const length = strokeLength(points)
    if (length <= 0 || share >= 1) {
        return [start, end]
    }
    let travelled = 0
    return points.map((point, index) => {
        if (index > 0) {
            travelled += distance(points[index - 1], point)
        }
        const target = pointAt(start, end, travelled / length)
        return pointAt(point, target, share)
    })
}

function segmentsCross(first, second, third, fourth) {
    const side = (origin, toward, point) => (toward[0] - origin[0]) * (point[1] - origin[1]) - (toward[1] - origin[1]) * (point[0] - origin[0])
    const firstSide = side(third, fourth, first)
    const secondSide = side(third, fourth, second)
    const thirdSide = side(first, second, third)
    const fourthSide = side(first, second, fourth)
    return firstSide * secondSide < 0 && thirdSide * fourthSide < 0
}

function segmentDistance(start, end, sweepStart, sweepEnd) {
    if (segmentsCross(start, end, sweepStart, sweepEnd)) {
        return 0
    }
    return Math.min(
        distanceToSegment(start, sweepStart, sweepEnd),
        distanceToSegment(end, sweepStart, sweepEnd),
        distanceToSegment(sweepStart, start, end),
        distanceToSegment(sweepEnd, start, end),
    )
}

export function isStrokeSwept(element, sweepStart, sweepEnd, radius) {
    if (element.type !== "stroke" || element.deleted || !element.points?.length) {
        return false
    }
    const reach = radius + (element.width ?? 0) / 2
    const points = element.points
    if (points.length === 1) {
        return distanceToSegment(points[0], sweepStart, sweepEnd) <= reach
    }
    for (let index = 1; index < points.length; index += 1) {
        if (segmentDistance(points[index - 1], points[index], sweepStart, sweepEnd) <= reach) {
            return true
        }
    }
    return false
}

const boundaryIterations = 30

function insideInterval(start, end, sweepStart, sweepEnd, reach) {
    if (segmentDistance(start, end, sweepStart, sweepEnd) > reach) {
        return null
    }
    const gap = (share) => distanceToSegment(pointAt(start, end, share), sweepStart, sweepEnd)
    let low = 0
    let high = 1
    for (let iteration = 0; iteration < boundaryIterations; iteration += 1) {
        const first = low + (high - low) / 3
        const second = high - (high - low) / 3
        if (gap(first) < gap(second)) {
            high = second
        } else {
            low = first
        }
    }
    const closest = (low + high) / 2
    if (gap(closest) > reach) {
        return null
    }
    const boundary = (outside, inside) => {
        if (gap(outside) <= reach) {
            return outside
        }
        for (let iteration = 0; iteration < boundaryIterations; iteration += 1) {
            const middle = (outside + inside) / 2
            if (gap(middle) <= reach) {
                inside = middle
            } else {
                outside = middle
            }
        }
        return (outside + inside) / 2
    }
    return [boundary(0, closest), boundary(1, closest)]
}

export function cutStroke(points, sweepStart, sweepEnd, reach) {
    if (points.length === 1) {
        return distanceToSegment(points[0], sweepStart, sweepEnd) <= reach ? [] : null
    }
    const pieces = []
    let current = distanceToSegment(points[0], sweepStart, sweepEnd) <= reach ? [] : [points[0]]
    let isTouched = false
    for (let index = 1; index < points.length; index += 1) {
        const start = points[index - 1]
        const end = points[index]
        const interval = insideInterval(start, end, sweepStart, sweepEnd, reach)
        if (!interval) {
            if (!current.length) {
                current.push(start)
            }
            current.push(end)
            continue
        }
        isTouched = true
        const [entry, exit] = interval
        if (entry > 0) {
            if (!current.length) {
                current.push(start)
            }
            current.push(pointAt(start, end, entry))
        }
        if (current.length) {
            pieces.push(current)
        }
        current = exit < 1 ? [pointAt(start, end, exit), end] : []
    }
    if (!isTouched) {
        return null
    }
    if (current.length) {
        pieces.push(current)
    }
    return pieces.map(cleaned).filter((piece) => piece.length >= 2)
}

export function tombstone(element, updated, device) {
    return { ...element, deleted: true, updated, device }
}

export function isNewer(updated, device, thanUpdated, thanDevice) {
    const first = timestampMilliseconds(updated)
    const second = timestampMilliseconds(thanUpdated)
    if (first !== second) {
        return first > second
    }
    return device >= thanDevice
}

export function mergeElement(first, second) {
    if (Boolean(first.deleted) !== Boolean(second.deleted)) {
        return first.deleted ? first : second
    }
    return isNewer(first.updated, first.device, second.updated, second.device) ? first : second
}

export function mergeHeader(first, second) {
    const newer = isNewer(first.updated, first.device, second.updated, second.device) ? first : second
    return {
        ...newer,
        deleted: Boolean(first.deleted || second.deleted),
        extent: { cols: Math.max(first.extent.cols, second.extent.cols), rows: Math.max(first.extent.rows, second.extent.rows) },
    }
}

export function mergeNotebook(first, second) {
    return mergeElement(first, second)
}

export function notebookPath(notebookId) {
    return `notebooks/${notebookId}/notebook.json`
}

export function pagePath(notebookId, pageId) {
    return `notebooks/${notebookId}/pages/${pageId}.json`
}

function canonical(value) {
    if (Array.isArray(value)) {
        return `[${value.map(canonical).join(",")}]`
    }
    if (value && typeof value === "object") {
        const keys = Object.keys(value).filter((key) => value[key] !== undefined && value[key] !== null).sort()
        return `{${keys.map((key) => `${JSON.stringify(key)}:${canonical(value[key])}`).join(",")}}`
    }
    return JSON.stringify(value)
}

export function encodePage(page) {
    const optional = (key) => (typeof page[key] === "string" || Number.isFinite(page[key]) ? [`  "${key}": ${canonical(page[key])},`] : [])
    const lines = [
        "{",
        ...optional("color"),
        `  "deleted": ${canonical(page.deleted)},`,
        `  "device": ${canonical(page.device)},`,
        `  "extent": ${canonical(page.extent)},`,
        ...optional("icon"),
        `  "id": ${canonical(page.id)},`,
        `  "notebook": ${canonical(page.notebook)},`,
        ...optional("order"),
        `  "schema_version": ${canonical(page.schema_version)},`,
        ...optional("title"),
        `  "updated": ${canonical(page.updated)},`,
    ]
    const elements = [...page.elements].sort(compareElements)
    if (elements.length === 0) {
        lines.push(`  "elements": []`)
    } else {
        lines.push(`  "elements": [`)
        lines.push(elements.map((element) => `    ${canonical(element)}`).join(",\n"))
        lines.push("  ]")
    }
    lines.push("}")
    return `${lines.join("\n")}\n`
}

export function encodeNotebook(notebook) {
    const keys = Object.keys(notebook).sort()
    const body = keys.map((key) => `  ${JSON.stringify(key)} : ${canonical(notebook[key])}`).join(",\n")
    return `{\n${body}\n}\n`
}

export function decodeFile(contents) {
    const value = JSON.parse(contents)
    if (value.schema_version !== schemaVersion) {
        return { value, isReadOnly: true }
    }
    if (Array.isArray(value.elements)) {
        value.elements.sort(compareElements)
    }
    return { value, isReadOnly: false }
}

export function repositoryPathKind(path) {
    const notebook = /^notebooks\/([^/]+)\/notebook\.json$/.exec(path)
    if (notebook) {
        return { kind: "notebook", notebookId: notebook[1] }
    }
    const page = /^notebooks\/([^/]+)\/pages\/([^/]+)\.json$/.exec(path)
    if (page) {
        return { kind: "page", notebookId: page[1], pageId: page[2] }
    }
    return null
}

export function polygonContains(polygon, point) {
    if (polygon.length < 3) {
        return false
    }
    let isInside = false
    let previous = polygon[polygon.length - 1]
    for (const current of polygon) {
        if ((current[1] > point[1]) !== (previous[1] > point[1])) {
            const crossingX = current[0] + ((point[1] - current[1]) / (previous[1] - current[1])) * (previous[0] - current[0])
            if (point[0] < crossingX) {
                isInside = !isInside
            }
        }
        previous = current
    }
    return isInside
}

function segmentsOf(points, isClosed) {
    const result = []
    for (let index = 1; index < points.length; index += 1) {
        result.push([points[index - 1], points[index]])
    }
    if (isClosed && points.length >= 2) {
        result.push([points[points.length - 1], points[0]])
    }
    return result
}

function anySegmentCrosses(first, second) {
    return first.some(([start, end]) => second.some(([otherStart, otherEnd]) => segmentsCross(start, end, otherStart, otherEnd)))
}

export function lassoTouchesLine(polygon, points) {
    if (polygon.length < 3 || points.length === 0) {
        return false
    }
    if (points.some((point) => polygonContains(polygon, point))) {
        return true
    }
    return anySegmentCrosses(segmentsOf(points, false), segmentsOf(polygon, true))
}

export function lassoTouchesArea(polygon, corners) {
    if (polygon.length < 3 || corners.length < 3) {
        return false
    }
    if (corners.some((point) => polygonContains(polygon, point)) || polygon.some((point) => polygonContains(corners, point))) {
        return true
    }
    return anySegmentCrosses(segmentsOf(corners, true), segmentsOf(polygon, true))
}

export function translatedElement(element, offset) {
    const moved = { ...element }
    if (element.points) {
        moved.points = element.points.map((point) => roundedPoint([point[0] + offset[0], point[1] + offset[1]]))
    }
    if (element.box) {
        moved.box = { ...element.box, x: element.box.x + offset[0], y: element.box.y + offset[1] }
    }
    if (element.placement) {
        moved.placement = { ...element.placement, x: element.placement.x + offset[0], y: element.placement.y + offset[1] }
    }
    return moved
}

export function scaledElement(element, anchor, factor) {
    const scale = (x, y) => [anchor[0] + (x - anchor[0]) * factor, anchor[1] + (y - anchor[1]) * factor]
    const scaled = { ...element }
    if (element.points) {
        scaled.points = element.points.map((point) => roundedPoint(scale(point[0], point[1])))
    }
    if (Number.isFinite(element.width)) {
        scaled.width = element.width * factor
    }
    if (Number.isFinite(element.font_size)) {
        scaled.font_size = element.font_size * factor
    }
    if (element.box) {
        const [x, y] = scale(element.box.x, element.box.y)
        scaled.box = { ...element.box, x, y, width: element.box.width * factor }
    }
    if (element.placement) {
        const [x, y] = scale(element.placement.x, element.placement.y)
        scaled.placement = { ...element.placement, x, y, scale: (element.placement.scale ?? 1) * factor }
    }
    return scaled
}

export function pointsBounds(points) {
    if (!points?.length) {
        return null
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
    return { minimumX, minimumY, maximumX, maximumY }
}
