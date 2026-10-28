import { AsciiBackground } from "./ascii.js"
import { create } from "./components.js"
import { GridScreen } from "./grid.js"
import { Library } from "./library.js"
import { MenuController } from "./menu.js"
import { animate, applyDesignVariables, duration } from "./motion.js"
import { ToolNav } from "./navigation.js"
import { PageScreen } from "./page.js"
import * as preferences from "./preferences.js"
import { SheetHost } from "./sheets.js"
import { SyncCoordinator } from "./sync.js"
import { loadTokens } from "./tokens.js"
import { TopBar } from "./topBar.js"

function sameRoute(first, second) {
    return JSON.stringify(first) === JSON.stringify(second)
}

class Navigator {
    constructor(app) {
        this.app = app
        this.route = { kind: "library" }
        this.sheet = null
        this.isChromeLeaving = false
        this.isPageChromeShown = false
        this.query = ""
        this.isReturningFromPage = false
        this.lastPage = null
        this.openingTile = null
    }

    show(request) {
        if (!request) {
            const current = this.sheet
            if (!current || current.isLeaving) {
                return
            }
            this.sheet = null
            current.leave()
            return
        }
        if (this.sheet) {
            this.sheet.element.remove()
        }
        this.sheet = new SheetHost(this.app, request)
    }

    go(route, tile = null) {
        if (sameRoute(route, this.route) || this.isChromeLeaving) {
            return
        }
        const isPage = route.kind === "page"
        if (isPage === (this.route.kind === "page")) {
            this.switchRoute(route, tile)
            return
        }
        this.isChromeLeaving = true
        this.isPageChromeShown = false
        this.app.chromeLeaving()
        setTimeout(() => {
            this.switchRoute(route, tile)
            this.isChromeLeaving = false
            this.app.refresh()
        })
    }

    showPageChrome(shown) {
        if (this.route.kind !== "page") {
            return
        }
        this.isPageChromeShown = shown
        this.app.refresh()
    }

    switchRoute(route, tile) {
        this.openingTile = tile ? { x: tile.left ?? tile.x, y: tile.top ?? tile.y, width: tile.width, height: tile.height } : null
        this.isReturningFromPage = this.route.kind === "page" && route.kind !== "page"
        if (route.kind === "page") {
            this.lastPage = { notebookId: route.notebookId, pageId: route.pageId }
        }
        this.route = route
        this.query = ""
        this.app.routeChanged()
    }
}

class App {
    constructor(root, library, sync) {
        this.root = root
        this.library = library
        this.sync = sync
        this.navigator = new Navigator(this)
        this.chromeLayout = { bottom: 0, back: null, frames: {} }
        this.keyboardHeight = 0
        this.screen = null
        this.screenIdentity = null
        this.ascii = new AsciiBackground()
        this.screenHost = create("div", "screen-host")
        this.topBarHost = create("div", "top-bar-host")
        this.navLayer = create("div", "nav-layer")
        this.overlayHost = create("div", "overlay-host")
        this.root.append(this.ascii.element, this.screenHost, this.navLayer, this.topBarHost, this.overlayHost)
        this.topBar = new TopBar(this)
        this.topBarHost.append(this.topBar.element)
        this.nav = new ToolNav(this.navLayer)
        this.menu = new MenuController(this.overlayHost)
        this.lastNavProps = null
        this.refreshRequest = null
        library.subscribe(() => this.refresh())
        sync.subscribe(() => this.refresh())
        preferences.subscribePreferences(() => this.refresh())
        window.addEventListener("resize", () => this.refresh())
        window.addEventListener("beforeunload", () => {
            this.library.finishText()
            this.library.flush()
        })
        this.watchKeyboard()
        this.routeChanged()
    }

    watchKeyboard() {
        const keyboard = navigator.virtualKeyboard
        if (!keyboard) {
            return
        }
        keyboard.overlaysContent = true
        keyboard.addEventListener("geometrychange", () => {
            this.keyboardHeight = keyboard.boundingRect.height
            this.navigator.sheet?.keyboardChanged()
            this.refresh()
        })
    }

    setChromeLayout(layout) {
        if (JSON.stringify(layout) === JSON.stringify(this.chromeLayout)) {
            return
        }
        this.chromeLayout = layout
        this.refresh()
    }

    chromeLeaving() {
        this.menu.dismiss()
        if (this.screen instanceof PageScreen) {
            this.screen.chromeLeaving()
        }
        this.refresh()
    }

    routeChanged() {
        const route = this.navigator.route
        this.menu.dismiss()
        this.library.finishText()
        this.library.flush()
        this.sync.flush()
        const identity = route.kind === "page" ? `page-${route.pageId}` : "folders"
        if (identity !== this.screenIdentity) {
            const previous = this.screen
            if (previous) {
                previous.destroy?.()
                previous.element.style.pointerEvents = "none"
                animate(previous.element, [{ opacity: 1 }, { opacity: 0 }], { milliseconds: duration("section_leave"), curveName: "power_two_in", fill: "forwards" }).finished.then(() => previous.element.remove())
            }
            this.screenIdentity = identity
            if (route.kind === "page") {
                this.screen = new PageScreen(this, route.notebookId, route.pageId)
            } else {
                this.screen = new GridScreen(this)
            }
            this.screenHost.append(this.screen.element)
            const isFlight = route.kind === "page" && this.navigator.openingTile
            if (!isFlight && !this.navigator.isReturningFromPage) {
                animate(this.screen.element, [{ opacity: 0, transform: "scale(0.96)" }, { opacity: 1, transform: "scale(1)" }], { milliseconds: duration("section_enter"), curveName: "power_two_out", delay: duration("section_enter_delay") })
            }
        }
        if (this.screen instanceof GridScreen) {
            this.screen.setFolder(route.kind === "notebook" ? route.notebookId : null)
        }
        this.refreshNow()
    }

    refresh() {
        if (this.refreshRequest) {
            return
        }
        this.refreshRequest = requestAnimationFrame(() => {
            this.refreshRequest = null
            this.refreshNow()
        })
    }

    refreshNow() {
        const isPage = this.navigator.route.kind === "page"
        this.ascii.element.hidden = !preferences.showsAsciiBackground()
        if (preferences.showsAsciiBackground()) {
            this.ascii.update({
                color: preferences.asciiBackgroundColor(),
                opacity: preferences.asciiBackgroundOpacity(),
                isMoving: preferences.isAsciiBackgroundMoving() && (preferences.doesAsciiBackgroundMoveInCanvas() || !isPage),
            })
        }
        this.topBar.update()
        this.screen?.update()
        if (!(this.screen instanceof PageScreen) && this.nav.props) {
            this.nav.update({ ...this.nav.props, isShown: false, subNavKey: null, panelKey: null })
        }
        this.navigator.sheet?.refresh()
    }
}

async function start() {
    await loadTokens()
    applyDesignVariables(document.documentElement)
    await document.fonts.load(`16px "Space Mono"`)
    await document.fonts.load(`700 16px "Space Mono"`)
    await document.fonts.load(`16px "Audiowide"`)
    const library = new Library()
    await library.open()
    const sync = new SyncCoordinator(library)
    await sync.open()
    new App(document.getElementById("root"), library, sync)
}

start()
