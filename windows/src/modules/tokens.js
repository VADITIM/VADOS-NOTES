export const tokens = {}

export async function loadTokens() {
    const tauri = window.__TAURI__
    const text = tauri
        ? await tauri.core.invoke("tokens")
        : await (await fetch(new URL("../../../shared/tokens.json", import.meta.url))).text()
    Object.assign(tokens, JSON.parse(text))
    return tokens
}

export function inkTokens(tool) {
    return tokens.tools[tool]
}

export function hexComponents(hex) {
    let text = hex.trim()
    if (text.startsWith("#")) {
        text = text.slice(1)
    }
    if (text.length !== 6 && text.length !== 8) {
        return { red: 0, green: 0, blue: 0, alpha: 1 }
    }
    const channel = (start) => parseInt(text.slice(start, start + 2), 16) / 255
    return { red: channel(0), green: channel(2), blue: channel(4), alpha: text.length === 8 ? channel(6) : 1 }
}

export function isLight(hex) {
    const components = hexComponents(hex)
    return components.red * 0.299 + components.green * 0.587 + components.blue * 0.114 > 0.5
}

export function withAlpha(hex, alpha) {
    const components = hexComponents(hex)
    const byte = (value) => Math.round(value * 255)
    return `rgba(${byte(components.red)}, ${byte(components.green)}, ${byte(components.blue)}, ${components.alpha * alpha})`
}

export function roleColor(role) {
    switch (role) {
    case "destructive": return tokens.semantic.destructive
    case "create": return tokens.semantic.create
    case "navigation": return tokens.semantic.navigation
    case "view": return tokens.semantic.view
    case "edit": return tokens.semantic.edit
    case "import": return tokens.semantic.import
    default: return tokens.palette.text_bright
    }
}
