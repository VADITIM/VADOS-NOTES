const browserFilesKey = "files"
const syncedPrefix = "synced/"
const syncStatePath = "synced/sync-state.json"
const browserTokenKey = "browserToken"

function browserFiles() {
    try {
        return JSON.parse(localStorage.getItem(browserFilesKey) ?? "{}")
    } catch {
        return {}
    }
}

function tauri() {
    return window.__TAURI__
}

export async function loadFiles() {
    if (tauri()) {
        return tauri().core.invoke("load_files", { synced: false })
    }
    return Object.entries(browserFiles()).filter(([path]) => !path.startsWith(syncedPrefix)).map(([path, contents]) => ({ path, contents }))
}

export async function loadSyncedFiles() {
    if (tauri()) {
        return tauri().core.invoke("load_files", { synced: true })
    }
    return Object.entries(browserFiles())
        .filter(([path]) => path.startsWith(`${syncedPrefix}notebooks/`))
        .map(([path, contents]) => ({ path: path.slice(syncedPrefix.length), contents }))
}

export async function writeFile(path, contents) {
    if (tauri()) {
        await tauri().core.invoke("write_file", { path, contents })
        return
    }
    const files = browserFiles()
    files[path] = contents
    try {
        localStorage.setItem(browserFilesKey, JSON.stringify(files))
    } catch {
        return
    }
}

export function writeSyncedFile(path, contents) {
    return writeFile(`${syncedPrefix}${path}`, contents)
}

export async function readSyncState() {
    const text = tauri() ? await tauri().core.invoke("read_sync_state") : browserFiles()[syncStatePath]
    if (!text) {
        return null
    }
    try {
        return JSON.parse(text)
    } catch {
        return null
    }
}

export function writeSyncState(state) {
    return writeFile(syncStatePath, `${JSON.stringify(state, null, 2)}\n`)
}

export async function readToken() {
    if (tauri()) {
        return (await tauri().core.invoke("read_token")) ?? null
    }
    return readSetting(browserTokenKey, null)
}

export async function saveToken(token) {
    if (tauri()) {
        await tauri().core.invoke("save_token", { token })
        return
    }
    writeSetting(browserTokenKey, token || null)
}

export function readSetting(key, fallback) {
    try {
        const stored = localStorage.getItem(key)
        return stored === null ? fallback : JSON.parse(stored)
    } catch {
        return fallback
    }
}

export function writeSetting(key, value) {
    try {
        localStorage.setItem(key, JSON.stringify(value))
    } catch {
        return
    }
}

export function deviceIdentity() {
    const existing = readSetting("deviceId", null)
    if (existing) {
        return existing
    }
    const created = `pc-${crypto.randomUUID().slice(0, 8).toLowerCase()}`
    writeSetting("deviceId", created)
    return created
}

const browserAssets = new Map()

export async function writeAsset(path, bytes) {
    if (tauri()) {
        await tauri().core.invoke("write_asset", bytes, { headers: { "asset-path": path } })
        return
    }
    browserAssets.set(path, bytes.slice())
}

export async function readAsset(path) {
    if (tauri()) {
        return new Uint8Array(await tauri().core.invoke("read_asset", { path }))
    }
    const bytes = browserAssets.get(path)
    if (!bytes) {
        throw new Error(`missing asset ${path}`)
    }
    return bytes.slice()
}

export async function exportPdf(name, bytes) {
    if (tauri()) {
        return tauri().core.invoke("export_pdf", bytes, { headers: { "export-name": encodeURIComponent(name) } }).then(() => true)
    }
    const link = document.createElement("a")
    link.href = URL.createObjectURL(new Blob([bytes], { type: "application/pdf" }))
    link.download = name
    link.click()
    setTimeout(() => URL.revokeObjectURL(link.href), 1000)
    return true
}

export async function backgroundArt() {
    if (tauri()) {
        return tauri().core.invoke("background_art")
    }
    return (await fetch(new URL("../../../ios/VadosNotes/Resources/background.txt", import.meta.url))).text()
}
