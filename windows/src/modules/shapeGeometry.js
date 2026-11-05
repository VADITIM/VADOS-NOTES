import { cleaned, distance, distanceToSegment, polygonContains, roundedPoint, simplified } from "./model.js"

export const curveSegments = 8
const samplesPerCurveSegment = 16
const samplesPerCorner = 8
const pointPrecision = 100

const minimumSize = 8
const closingShare = 0.22
const minimumPerimeterShare = 1.8
const ellipseMeanDeviation = 0.09
const ellipseLargestDeviation = 0.28
const circleRatio = 0.12
const simplifyShare = 0.055
const straightCornerDegrees = 150
const shortEdgeShare = 0.06
const rightAngleTolerance = 16
const parallelTolerance = 12
const axisSnapDegrees = 8
const polygonNames = { 3: "triangle", 4: "quadrilateral", 5: "pentagon", 6: "hexagon", 7: "heptagon", 8: "octagon" }

export function polygonShape(name, anchors) {
    return { outline: "polygon", name, anchors: anchors.map(roundedPoint), radii: anchors.map(() => 0) }
}

export function ellipseShape(name, centre, radiusX, radiusY) {
    const span = (2 * Math.PI) / curveSegments
    const reach = (4 / 3) * Math.tan(span / 4)
    const anchors = []
    const handles = []
    for (let index = 0; index < curveSegments; index += 1) {
        const angle = index * span
        anchors.push([centre[0] + radiusX * Math.cos(angle), centre[1] + radiusY * Math.sin(angle)])
    }
    for (let index = 0; index < curveSegments; index += 1) {
        const angle = index * span
        const next = (index + 1) * span
        const start = anchors[index]
        const end = anchors[(index + 1) % curveSegments]
        handles.push([start[0] - radiusX * Math.sin(angle) * reach, start[1] + radiusY * Math.cos(angle) * reach])
        handles.push([end[0] + radiusX * Math.sin(next) * reach, end[1] - radiusY * Math.cos(next) * reach])
    }
    return { outline: "curve", name, anchors: anchors.map(roundedPoint), handles: handles.map(roundedPoint) }
}

export function isValidShape(shape) {
    if (!shape || !Array.isArray(shape.anchors)) {
        return false
    }
    if (shape.outline === "polygon") {
        return shape.anchors.length >= 3 && (!shape.radii || shape.radii.length === shape.anchors.length)
    }
    return shape.outline === "curve" && shape.anchors.length >= 2 && shape.handles?.length === shape.anchors.length * 2
}

function cubic(start, first, second, end, share) {
    const rest = 1 - share
    const a = rest * rest * rest
    const b = 3 * rest * rest * share
    const c = 3 * rest * share * share
    const d = share * share * share
    return [a * start[0] + b * first[0] + c * second[0] + d * end[0], a * start[1] + b * first[1] + c * second[1] + d * end[1]]
}

function corner(shape, index) {
    if (shape.outline !== "polygon" || shape.anchors.length < 3) {
        return null
    }
    const count = shape.anchors.length
    const point = shape.anchors[index]
    const previous = shape.anchors[(index + count - 1) % count]
    const next = shape.anchors[(index + 1) % count]
    const previousLength = distance(point, previous)
    const nextLength = distance(point, next)
    if (previousLength <= 1e-9 || nextLength <= 1e-9) {
        return null
    }
    const towardPrevious = [(previous[0] - point[0]) / previousLength, (previous[1] - point[1]) / previousLength]
    const towardNext = [(next[0] - point[0]) / nextLength, (next[1] - point[1]) / nextLength]
    const cosine = Math.max(-1, Math.min(1, towardPrevious[0] * towardNext[0] + towardPrevious[1] * towardNext[1]))
    const sumX = towardPrevious[0] + towardNext[0]
    const sumY = towardPrevious[1] + towardNext[1]
    const length = Math.hypot(sumX, sumY)
    return { point, towardPrevious, towardNext, previousLength, nextLength, halfAngle: Math.acos(cosine) / 2, bisector: length > 1e-9 ? [sumX / length, sumY / length] : null }
}

export function maximumRadius(shape, index) {
    const found = corner(shape, index)
    if (!found || found.halfAngle <= 1e-6 || found.halfAngle >= Math.PI / 2 - 1e-6) {
        return 0
    }
    return (Math.min(found.previousLength, found.nextLength) / 2) * Math.tan(found.halfAngle)
}

export function radiusAt(shape, index) {
    const radius = shape.radii?.[index]
    return Number.isFinite(radius) ? Math.max(0, Math.min(radius, maximumRadius(shape, index))) : 0
}

function cornerPoints(shape, index) {
    const radius = radiusAt(shape, index)
    const found = corner(shape, index)
    if (radius <= 0 || !found || !found.bisector) {
        return [shape.anchors[index]]
    }
    const reach = radius / Math.tan(found.halfAngle)
    const start = [found.point[0] + found.towardPrevious[0] * reach, found.point[1] + found.towardPrevious[1] * reach]
    const end = [found.point[0] + found.towardNext[0] * reach, found.point[1] + found.towardNext[1] * reach]
    const centreDistance = radius / Math.sin(found.halfAngle)
    const centre = [found.point[0] + found.bisector[0] * centreDistance, found.point[1] + found.bisector[1] * centreDistance]
    const startAngle = Math.atan2(start[1] - centre[1], start[0] - centre[0])
    let sweep = Math.atan2(end[1] - centre[1], end[0] - centre[0]) - startAngle
    while (sweep > Math.PI) {
        sweep -= 2 * Math.PI
    }
    while (sweep < -Math.PI) {
        sweep += 2 * Math.PI
    }
    const points = []
    for (let step = 0; step <= samplesPerCorner; step += 1) {
        const angle = startAngle + (sweep * step) / samplesPerCorner
        points.push([centre[0] + radius * Math.cos(angle), centre[1] + radius * Math.sin(angle)])
    }
    return points
}

export function outlinePoints(shape) {
    if (!isValidShape(shape)) {
        return shape?.anchors ?? []
    }
    const points = []
    if (shape.outline === "curve") {
        const count = shape.anchors.length
        for (let index = 0; index < count; index += 1) {
            const start = shape.anchors[index]
            const first = shape.handles[index * 2]
            const second = shape.handles[index * 2 + 1]
            const end = shape.anchors[(index + 1) % count]
            for (let step = 0; step < samplesPerCurveSegment; step += 1) {
                points.push(cubic(start, first, second, end, step / samplesPerCurveSegment))
            }
        }
    } else {
        shape.anchors.forEach((unused, index) => points.push(...cornerPoints(shape, index)))
    }
    if (points.length) {
        points.push(points[0])
    }
    return cleaned(points)
}

export function radiusHandle(shape, index, inset) {
    const found = corner(shape, index)
    if (!found || !found.bisector || found.halfAngle <= 1e-6) {
        return null
    }
    const reach = inset + radiusAt(shape, index) * (1 / Math.sin(found.halfAngle) - 1)
    return [found.point[0] + found.bisector[0] * reach, found.point[1] + found.bisector[1] * reach]
}

export function radiusForHandle(shape, index, point, inset) {
    const found = corner(shape, index)
    if (!found || !found.bisector || found.halfAngle <= 1e-6) {
        return 0
    }
    const along = (point[0] - found.point[0]) * found.bisector[0] + (point[1] - found.point[1]) * found.bisector[1]
    const growth = 1 / Math.sin(found.halfAngle) - 1
    if (growth <= 1e-9) {
        return 0
    }
    return Math.max(0, Math.min(maximumRadius(shape, index), (along - inset) / growth))
}

export function withRadius(shape, radius, index) {
    if (shape.outline !== "polygon" || index < 0 || index >= shape.anchors.length) {
        return shape
    }
    const radii = shape.radii ? [...shape.radii] : shape.anchors.map(() => 0)
    radii[index] = Math.round(Math.max(0, Math.min(radius, maximumRadius(shape, index))) * pointPrecision) / pointPrecision
    return { ...shape, radii }
}

export function withAllRadii(shape, radius) {
    return shape.anchors.reduce((current, unused, index) => withRadius(current, radius, index), shape)
}

export function handleAnchor(shape, index) {
    return index % 2 === 0 ? index / 2 : (Math.floor(index / 2) + 1) % Math.max(1, shape.anchors.length)
}

export function movingAnchor(shape, index, point) {
    if (index < 0 || index >= shape.anchors.length) {
        return shape
    }
    const target = roundedPoint(point)
    const offset = [target[0] - shape.anchors[index][0], target[1] - shape.anchors[index][1]]
    const anchors = [...shape.anchors]
    anchors[index] = target
    let moved = { ...shape, anchors }
    if (shape.outline === "curve" && shape.handles) {
        const count = shape.anchors.length
        const handles = [...shape.handles]
        for (const handle of [index * 2, ((index + count - 1) % count) * 2 + 1]) {
            if (handles[handle]) {
                handles[handle] = roundedPoint([handles[handle][0] + offset[0], handles[handle][1] + offset[1]])
            }
        }
        moved.handles = handles
    }
    if (shape.outline === "polygon" && shape.radii) {
        moved = { ...moved, radii: shape.radii.map((radius, corner) => Math.min(radius, maximumRadius(moved, corner))) }
    }
    return moved
}

export function movingHandle(shape, index, point) {
    if (shape.outline !== "curve" || !shape.handles?.[index]) {
        return shape
    }
    const handles = [...shape.handles]
    handles[index] = roundedPoint(point)
    return { ...shape, handles }
}

export function sameShape(first, second) {
    return JSON.stringify(first ?? null) === JSON.stringify(second ?? null)
}

function angle(point, previous, next) {
    const first = [previous[0] - point[0], previous[1] - point[1]]
    const second = [next[0] - point[0], next[1] - point[1]]
    const lengths = Math.hypot(...first) * Math.hypot(...second)
    if (lengths <= 1e-9) {
        return 180
    }
    return (Math.acos(Math.max(-1, Math.min(1, (first[0] * second[0] + first[1] * second[1]) / lengths))) * 180) / Math.PI
}

function cornerAngle(corners, index) {
    const count = corners.length
    return angle(corners[index], corners[(index + count - 1) % count], corners[(index + 1) % count])
}

function merged(points, minimumEdge) {
    const corners = [...points]
    while (corners.length > 3) {
        const straight = corners.findIndex((unused, index) => cornerAngle(corners, index) > straightCornerDegrees)
        if (straight >= 0) {
            corners.splice(straight, 1)
            continue
        }
        const short = corners.findIndex((point, index) => distance(point, corners[(index + 1) % corners.length]) < minimumEdge)
        if (short < 0) {
            break
        }
        const next = (short + 1) % corners.length
        corners.splice(cornerAngle(corners, short) > cornerAngle(corners, next) ? short : next, 1)
    }
    return corners
}

function direction(start, end) {
    return Math.atan2(end[1] - start[1], end[0] - start[0])
}

function isRectangle(corners) {
    return corners.every((unused, index) => Math.abs(cornerAngle(corners, index) - 90) <= rightAngleTolerance)
}

function isClockwise(points) {
    let total = 0
    points.forEach((point, index) => {
        const next = points[(index + 1) % points.length]
        total += (next[0] - point[0]) * (next[1] + point[1])
    })
    return total < 0
}

function rectangle(corners) {
    const edges = corners.map((point, index) => [point, corners[(index + 1) % corners.length]])
    const longest = edges.reduce((best, edge) => (distance(edge[0], edge[1]) > distance(best[0], best[1]) ? edge : best), edges[0])
    let heading = direction(longest[0], longest[1])
    const quarter = Math.PI / 2
    const snapped = Math.round(heading / quarter) * quarter
    if ((Math.abs(heading - snapped) * 180) / Math.PI <= axisSnapDegrees) {
        heading = snapped
    }
    const along = [Math.cos(heading), Math.sin(heading)]
    const across = [-along[1], along[0]]
    const us = corners.map((point) => point[0] * along[0] + point[1] * along[1])
    const vs = corners.map((point) => point[0] * across[0] + point[1] * across[1])
    const point = (u, v) => [along[0] * u + across[0] * v, along[1] * u + across[1] * v]
    const lowU = Math.min(...us)
    const highU = Math.max(...us)
    const lowV = Math.min(...vs)
    const highV = Math.max(...vs)
    const box = [point(lowU, lowV), point(highU, lowV), point(highU, highV), point(lowU, highV)]
    let start = 0
    box.forEach((candidate, index) => {
        if (distance(candidate, corners[0]) < distance(box[start], corners[0])) {
            start = index
        }
    })
    const ordered = [0, 1, 2, 3].map((offset) => box[(start + offset) % 4])
    return isClockwise(ordered) === isClockwise(corners) ? ordered : [ordered[0], ordered[3], ordered[2], ordered[1]]
}

function trapezoid(corners) {
    for (const [firstEdge, secondEdge] of [[0, 2], [1, 3]]) {
        const first = [corners[firstEdge], corners[(firstEdge + 1) % 4]]
        const second = [corners[secondEdge], corners[(secondEdge + 1) % 4]]
        let difference = Math.abs(direction(first[0], first[1]) - direction(second[1], second[0]))
        while (difference > Math.PI) {
            difference = Math.abs(difference - 2 * Math.PI)
        }
        if ((difference * 180) / Math.PI > parallelTolerance) {
            continue
        }
        const heading = distance(first[0], first[1]) >= distance(second[0], second[1]) ? direction(first[0], first[1]) : direction(second[1], second[0])
        const along = [Math.cos(heading), Math.sin(heading)]
        const result = [...corners]
        for (const edge of [firstEdge, secondEdge]) {
            const start = corners[edge]
            const end = corners[(edge + 1) % 4]
            const middle = [(start[0] + end[0]) / 2, (start[1] + end[1]) / 2]
            for (const [position, point] of [[edge, start], [(edge + 1) % 4, end]]) {
                const reach = (point[0] - middle[0]) * along[0] + (point[1] - middle[1]) * along[1]
                result[position] = [middle[0] + along[0] * reach, middle[1] + along[1] * reach]
            }
        }
        return result
    }
    return null
}

function ellipse(points, minimumX, maximumX, minimumY, maximumY) {
    const radiusX = (maximumX - minimumX) / 2
    const radiusY = (maximumY - minimumY) / 2
    if (radiusX <= 0 || radiusY <= 0) {
        return null
    }
    const centre = [(minimumX + maximumX) / 2, (minimumY + maximumY) / 2]
    const deviations = points.map((point) => Math.abs(Math.hypot((point[0] - centre[0]) / radiusX, (point[1] - centre[1]) / radiusY) - 1))
    const mean = deviations.reduce((total, value) => total + value, 0) / deviations.length
    if (mean > ellipseMeanDeviation || Math.max(...deviations) > ellipseLargestDeviation) {
        return null
    }
    if (Math.abs(radiusX - radiusY) / Math.max(radiusX, radiusY) <= circleRatio) {
        const radius = (radiusX + radiusY) / 2
        return ellipseShape("circle", centre, radius, radius)
    }
    return ellipseShape("ellipse", centre, radiusX, radiusY)
}

function polygon(closed, diagonal, perimeter) {
    const start = closed[0]
    let farthest = 0
    closed.forEach((point, index) => {
        if (distance(point, start) > distance(closed[farthest], start)) {
            farthest = index
        }
    })
    if (farthest <= 0 || farthest >= closed.length - 1) {
        return null
    }
    const tolerance = diagonal * simplifyShare
    const firstHalf = simplified(closed.slice(0, farthest + 1), tolerance)
    const secondHalf = simplified(closed.slice(farthest), tolerance)
    const corners = merged([...firstHalf.slice(0, -1), ...secondHalf.slice(0, -1)], perimeter * shortEdgeShare)
    const name = polygonNames[corners.length]
    if (!name) {
        return null
    }
    if (corners.length === 4) {
        if (isRectangle(corners)) {
            return polygonShape("rectangle", rectangle(corners))
        }
        const parallel = trapezoid(corners)
        if (parallel) {
            return polygonShape("trapezoid", parallel)
        }
    }
    return polygonShape(name, corners)
}

export function recognizeShape(points) {
    if (points.length < 8) {
        return null
    }
    const xs = points.map((point) => point[0])
    const ys = points.map((point) => point[1])
    const minimumX = Math.min(...xs)
    const maximumX = Math.max(...xs)
    const minimumY = Math.min(...ys)
    const maximumY = Math.max(...ys)
    const diagonal = Math.hypot(maximumX - minimumX, maximumY - minimumY)
    if (diagonal < minimumSize) {
        return null
    }
    let perimeter = 0
    for (let index = 1; index < points.length; index += 1) {
        perimeter += distance(points[index - 1], points[index])
    }
    const first = points[0]
    const last = points[points.length - 1]
    if (distance(first, last) > diagonal * closingShare || perimeter < diagonal * minimumPerimeterShare) {
        return null
    }
    const closed = first[0] === last[0] && first[1] === last[1] ? [...points] : [...points, first]
    return ellipse(closed, minimumX, maximumX, minimumY, maximumY) ?? polygon(closed, diagonal, perimeter)
}

export function shapeElementAt(point, reach, elements) {
    const found = [...elements].reverse().find((element) => {
        if (!element.shape || !element.points || element.points.length < 2) {
            return false
        }
        if (polygonContains(element.points, point)) {
            return true
        }
        const tolerance = reach + (element.width ?? 0) / 2
        for (let index = 1; index < element.points.length; index += 1) {
            if (distanceToSegment(point, element.points[index - 1], element.points[index]) <= tolerance) {
                return true
            }
        }
        return false
    })
    return found ?? null
}
