import { tokens } from "./tokens.js"
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


export function glyph(name, { color, size = 22 } = {}) {
    const svg = document.createElementNS(svgNamespace, "svg")
    svg.classList.add("glyph")
    svg.setAttribute("viewBox", "0 0 24 24")
    svg.setAttribute("width", String(size))
    svg.setAttribute("height", String(size))
    svg.setAttribute("aria-hidden", "true")
    const path = document.createElementNS(svgNamespace, "path")
    path.setAttribute("d", tokens.glyphs[name] ?? "")
    svg.append(path)
    if (color) {
        svg.style.color = color
    }
    return svg
}
