export const schemaVersion = 1
export const cellWidth = 210
export const cellHeight = 297
export const minimumPointSpacing = 0.15
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

export function shouldAppend(point, previous) {
    return !previous || distance(point, previous) >= minimumPointSpacing
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

export function isStrokeHit(element, point, radius) {
    if (element.type !== "stroke" || element.deleted || !element.points?.length) {
        return false
    }
    const reach = radius + (element.width ?? 0) / 2
    const points = element.points
    if (points.length === 1) {
        return distance(point, points[0]) <= reach
    }
    for (let index = 1; index < points.length; index += 1) {
        if (distanceToSegment(point, points[index - 1], points[index]) <= reach) {
            return true
        }
    }
    return false
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
    const lines = [
        "{",
        `  "deleted": ${canonical(page.deleted)},`,
        `  "device": ${canonical(page.device)},`,
        `  "extent": ${canonical(page.extent)},`,
        `  "id": ${canonical(page.id)},`,
        `  "notebook": ${canonical(page.notebook)},`,
        `  "schema_version": ${canonical(page.schema_version)},`,
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
