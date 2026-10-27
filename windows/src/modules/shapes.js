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
