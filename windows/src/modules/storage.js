const browserFilesKey = "files"

function browserFiles() {
    try {
        return JSON.parse(localStorage.getItem(browserFilesKey) ?? "{}")
    } catch {
        return {}
    }
}

export async function loadFiles() {
    const tauri = window.__TAURI__
    if (tauri) {
        return tauri.core.invoke("load_files")
    }
    return Object.entries(browserFiles()).map(([path, contents]) => ({ path, contents }))
}

export async function writeFile(path, contents) {
    const tauri = window.__TAURI__
    if (tauri) {
        await tauri.core.invoke("write_file", { path, contents })
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
