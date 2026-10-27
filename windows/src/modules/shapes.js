const squircleExponent = 5
const stepsPerCorner = 12
const extentPerRadius = 1.8
const svgNamespace = "http://www.w3.org/2000/svg"

export const squircleRadius = { sheet: 30, panel: 22, tile: 18, slot: 14 }

function superellipse(value) {
    const magnitude = Math.pow(Math.abs(value), 2 / squircleExponent)
    return value < 0 ? -magnitude : magnitude
}

export function squirclePath(width, height, radius, inset = 0) {
    const left = inset
    const top = inset
    const right = width - inset
    const bottom = height - inset
    const extent = Math.min(radius * extentPerRadius, Math.min(right - left, bottom - top) / 2)
    if (extent <= 0) {
        return `M${left} ${top}H${right}V${bottom}H${left}Z`
    }
    const corners = [
        [left + extent, top + extent, Math.PI],
        [right - extent, top + extent, 1.5 * Math.PI],
        [right - extent, bottom - extent, 0],
        [left + extent, bottom - extent, 0.5 * Math.PI],
    ]
    const commands = []
    for (const [centerX, centerY, startAngle] of corners) {
        for (let step = 0; step <= stepsPerCorner; step += 1) {
            const angle = startAngle + (Math.PI / 2) * (step / stepsPerCorner)
            const x = centerX + extent * superellipse(Math.cos(angle))
            const y = centerY + extent * superellipse(Math.sin(angle))
            commands.push(`${commands.length === 0 ? "M" : "L"}${x.toFixed(2)} ${y.toFixed(2)}`)
        }
    }
    return `${commands.join("")}Z`
}

const decorated = new WeakMap()
const resizeObserver = new ResizeObserver((entries) => {
    for (const entry of entries) {
        decorated.get(entry.target)?.()
    }
})

export function squircle(element, { radius, fill = "none", border = "none", borderWidth = 1, clip = false }) {
    let svg = element.querySelector(":scope > svg.squircle")
    if (!svg) {
        svg = document.createElementNS(svgNamespace, "svg")
        svg.classList.add("squircle")
        svg.setAttribute("aria-hidden", "true")
        svg.append(document.createElementNS(svgNamespace, "path"), document.createElementNS(svgNamespace, "path"))
        element.prepend(svg)
    }
    const [fillPath, borderPath] = svg.children
    const redraw = () => {
        const width = element.offsetWidth
        const height = element.offsetHeight
        if (width === 0 || height === 0) {
            return
        }
        const path = squirclePath(width, height, radius)
        svg.setAttribute("viewBox", `0 0 ${width} ${height}`)
        fillPath.setAttribute("d", path)
        fillPath.setAttribute("fill", fill)
        borderPath.setAttribute("d", path)
        borderPath.setAttribute("fill", "none")
        borderPath.setAttribute("stroke", border)
        borderPath.setAttribute("stroke-width", String(borderWidth))
        if (clip) {
            element.style.clipPath = `path("${path}")`
        }
    }
    decorated.set(element, redraw)
    resizeObserver.observe(element)
    redraw()
    return element
}

const glyphPaths = {
    pen: "M4 20L6 14L16 4L20 8L10 18Z M14 6L18 10 M4 20L7.5 16.5",
    pencil: "M4 20L6 14L16 4L20 8L10 18Z M6 14L10 18 M13.5 6.5L17.5 10.5",
    marker: "M6 18L6 14L15 5L19 9L10 18Z M4 21L11 21",
    eraser: "M3 15L12 6L20 14L13 21L9 21Z M7.5 10.5L15.5 18.5 M13 21L21 21",
    text: "M6 6L18 6 M12 6L12 19 M9 19L15 19",
    undo: "M9 5L4 10L9 15 M4 10C17 10 21 14 14 19",
    redo: "M15 5L20 10L15 15 M20 10C7 10 3 14 10 19",
    back: "M15 5L8 12L15 19",
    plus: "M12 5L12 19 M5 12L19 12",
    more: "M4.7 12a1.3 1.3 0 1 0 2.6 0a1.3 1.3 0 1 0 -2.6 0 M10.7 12a1.3 1.3 0 1 0 2.6 0a1.3 1.3 0 1 0 -2.6 0 M16.7 12a1.3 1.3 0 1 0 2.6 0a1.3 1.3 0 1 0 -2.6 0",
    sync: "M19 9C17 4 8 3 5 10 M19 4L19 9L14 9 M5 15C7 20 16 21 19 14 M5 20L5 15L10 15",
    check: "M5 12.5L10 17.5L19.5 7",
    close: "M6 6L18 18 M18 6L6 18",
    move: "M12 3L12 21 M3 12L21 12 M9 6L12 3L15 6 M9 18L12 21L15 18 M6 9L3 12L6 15 M18 9L21 12L18 15",
    erase_stroke: "M3 15C6 8 9 8 12 12C15 16 18 16 21 9 M5 5L19 19",
    erase_area: "M2 12L7 12 M17 12L22 12 M7 12a5 5 0 1 0 10 0a5 5 0 1 0 -10 0",
    paper: "M6 3L14 3L19 8L19 21L6 21Z M14 3L14 8L19 8",
    settings: "M4 7L10 7 M14 7L20 7 M10 7a2 2 0 1 0 4 0a2 2 0 1 0 -4 0 M4 17L14 17 M18 17L20 17 M14 17a2 2 0 1 0 4 0a2 2 0 1 0 -4 0",
    folder: "M3 6L9.5 6L11.5 8.5L21 8.5L21 19L3 19Z",
    folder_add: "M3 6L9.5 6L11.5 8.5L21 8.5L21 19L3 19Z M12 11L12 17 M9 14L15 14",
    note: "M6 3L14 3L19 8L19 21L6 21Z M14 3L14 8L19 8 M9 12L16 12 M9 16L14 16",
    note_add: "M6 3L14 3L19 8L19 21L6 21Z M14 3L14 8L19 8 M12.5 11L12.5 18 M9 14.5L16 14.5",
    book: "M4 5L10 5C11 5 12 6 12 7L12 20C12 19 11 18 10 18L4 18Z M20 5L14 5C13 5 12 6 12 7 M20 5L20 18L14 18C13 18 12 19 12 20",
    star: "M12 3L14.6 9L21 9.6L16.2 13.8L17.6 20.2L12 16.8L6.4 20.2L7.8 13.8L3 9.6L9.4 9Z",
    heart: "M12 20C5 15 3 11.5 3 8.5C3 6 5 4 7.5 4C9.5 4 11 5.2 12 7C13 5.2 14.5 4 16.5 4C19 4 21 6 21 8.5C21 11.5 19 15 12 20Z",
    bolt: "M13 2L5 13.5L11 13.5L10 22L19 10L13 10Z",
    flag: "M5 21L5 4 M5 4L18 4L15 8.5L18 13L5 13",
    bookmark: "M6 3L18 3L18 21L12 16L6 21Z",
    pin: "M12 21C8 16 5.5 12.5 5.5 9.5a6.5 6.5 0 0 1 13 0C18.5 12.5 16 16 12 21Z M10 9.5a2 2 0 1 0 4 0a2 2 0 1 0 -4 0",
    bulb: "M9 18L15 18 M10 21L14 21 M9 15C7 13.5 6 11.8 6 9.5a6 6 0 0 1 12 0C18 11.8 17 13.5 15 15Z",
    code: "M8 7L3 12L8 17 M16 7L21 12L16 17 M14 4L10 20",
    music: "M9 18L9 5L20 3L20 16 M4 18a2.5 2.5 0 1 0 5 0a2.5 2.5 0 1 0 -5 0 M15 16a2.5 2.5 0 1 0 5 0a2.5 2.5 0 1 0 -5 0",
    home: "M3 11L12 3L21 11 M5 9.5L5 21L19 21L19 9.5 M10 21L10 15L14 15L14 21",
    search: "M4 10.5a6.5 6.5 0 1 0 13 0a6.5 6.5 0 1 0 -13 0 M15.5 15.5L21 21",
    text_size: "M2 19L7.5 5L13 19 M4.2 14L10.8 14 M14 19L18 10L22 19 M15.4 16L20.6 16",
}

export function glyph(name, { color, size = 22 } = {}) {
    const svg = document.createElementNS(svgNamespace, "svg")
    svg.classList.add("glyph")
    svg.setAttribute("viewBox", "0 0 24 24")
    svg.setAttribute("width", String(size))
    svg.setAttribute("height", String(size))
    svg.setAttribute("aria-hidden", "true")
    const path = document.createElementNS(svgNamespace, "path")
    path.setAttribute("d", glyphPaths[name])
    svg.append(path)
    if (color) {
        svg.style.color = color
    }
    return svg
}
