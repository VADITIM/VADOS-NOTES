import { create } from "./components.js"
import { Library } from "./library.js"
import { MenuController } from "./menu.js"
import { applyDesignVariables, fadeIn, fadeOut, overlayEnter, overlayLeave, sectionEnter, sectionLeave } from "./motion.js"
import { ToolNav } from "./navigation.js"
import { subscribePreferences } from "./preferences.js"
import { LibraryScreen, NotebookScreen, PageScreen } from "./screens.js"
import { buildSheet } from "./sheets.js"
import { loadTokens, tokens } from "./tokens.js"

class App {
    constructor(root, library) {
        this.root = root
        this.library = library
        this.route = { kind: "library" }
        this.screen = null
        this.sheet = null
        this.screenHost = create("div", "screen-host")
        this.navLayer = create("div", "nav-layer")
        this.overlayHost = create("div", "overlay-host")
        this.root.append(this.screenHost, this.navLayer, this.overlayHost)
        this.nav = new ToolNav(this.navLayer)
        this.menu = new MenuController(this.overlayHost)
        this.library.subscribe(() => this.screen?.update())
        subscribePreferences(() => this.screen?.update())
        window.addEventListener("beforeunload", () => {
            this.library.finishText()
            this.library.flush()
        })
        this.showScreen()
    }

    syncStatus() {
        return { label: "Not connected", color: tokens.palette.text_muted }
    }

    go(route) {
        if (JSON.stringify(route) === JSON.stringify(this.route)) {
            return
        }
        this.route = route
        this.menu.dismiss()
        this.library.finishText()
        this.library.flush()
        this.showScreen()
    }

    showScreen() {
        const previous = this.screen
        if (previous) {
            previous.destroy?.()
            previous.element.style.pointerEvents = "none"
            sectionLeave(previous.element).then(() => previous.element.remove())
        }
        const route = this.route
        if (route.kind === "notebook") {
            this.screen = new NotebookScreen(this, route.notebookId)
        } else if (route.kind === "page") {
            this.screen = new PageScreen(this, route.notebookId, route.pageId)
        } else {
            this.screen = new LibraryScreen(this)
        }
        this.screenHost.append(this.screen.element)
        sectionEnter(this.screen.element)
        this.screen.update()
    }

    showSheet(request) {
        if (this.sheet) {
            const { backdrop, panel } = this.sheet
            this.sheet = null
            fadeOut(backdrop).then(() => backdrop.remove())
            overlayLeave(panel).then(() => panel.remove())
        }
        if (!request) {
            return
        }
        const panel = buildSheet(this, request)
        if (!panel) {
            return
        }
        const backdrop = create("div", "sheet-backdrop")
        backdrop.addEventListener("pointerdown", () => this.showSheet(null))
        const host = create("div", "sheet-host", panel)
        host.addEventListener("pointerdown", (event) => {
            if (event.target === host) {
                this.showSheet(null)
            }
        })
        const keyDown = (event) => {
            if (event.key === "Escape") {
                this.showSheet(null)
            }
        }
        host.addEventListener("keydown", keyDown)
        this.overlayHost.append(backdrop, host)
        fadeIn(backdrop)
        overlayEnter(panel)
        this.sheet = { backdrop, panel: host }
        requestAnimationFrame(() => {
            panel.focusTarget?.focus()
            if (panel.selectsAll) {
                panel.focusTarget?.select()
            }
        })
    }
}

async function start() {
    await loadTokens()
    applyDesignVariables(document.documentElement)
    await document.fonts.load(`16px "Space Mono"`)
    await document.fonts.load(`16px "Audiowide"`)
    const library = new Library()
    await library.open()
    new App(document.getElementById("root"), library)
}

start()
