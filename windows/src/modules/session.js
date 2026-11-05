import { readSetting, writeSetting } from "./storage.js"

const viewsKey = "noteViews"
const routeKey = "lastRoute"
const viewLimit = 300
const flushDelay = 400

let pending = new Map()
let flushTimer = null

function storedViews() {
    const stored = readSetting(viewsKey, {})
    return stored && typeof stored === "object" ? stored : {}
}

export function noteView(pageId) {
    const values = pending.get(pageId) ?? storedViews()[pageId]
    if (!Array.isArray(values) || values.length < 3 || !(values[0] > 0)) {
        return null
    }
    return { scale: values[0], centerX: values[1], centerY: values[2] }
}

export function rememberNoteView(pageId, { scale, centerX, centerY }) {
    pending.set(pageId, [scale, centerX, centerY, Date.now()])
    clearTimeout(flushTimer)
    flushTimer = setTimeout(flushSession, flushDelay)
}

export function flushSession() {
    clearTimeout(flushTimer)
    flushTimer = null
    if (pending.size === 0) {
        return
    }
    let views = { ...storedViews(), ...Object.fromEntries(pending) }
    pending = new Map()
    const entries = Object.entries(views)
    if (entries.length > viewLimit) {
        views = Object.fromEntries(entries.sort((first, second) => (second[1][3] ?? 0) - (first[1][3] ?? 0)).slice(0, viewLimit))
    }
    writeSetting(viewsKey, views)
}

export function rememberRoute(route) {
    writeSetting(routeKey, route.kind === "page" ? { kind: "page", notebookId: route.notebookId, pageId: route.pageId } : route.kind === "notebook" ? { kind: "notebook", notebookId: route.notebookId } : { kind: "library" })
}

export function lastRoute() {
    const route = readSetting(routeKey, null)
    return route && typeof route === "object" ? route : null
}
