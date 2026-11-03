import { create, holdable, inlineTitle, microLabel, revealLabel, roundIconButton } from "./components.js"
import { creationDate } from "./model.js"
import { duration } from "./motion.js"
import { PillMotion, hideTurned, labelReveal, popTogether, revealElement, shapePillShell } from "./pill.js"
import { glyph } from "./shapes.js"
import { tokens } from "./tokens.js"

const searchPrompt = "Search"
const bareTitleSize = 15
const topBarControlHeight = 48
const folderTitleSize = topBarControlHeight / 2

function createdText(pageId) {
    const date = creationDate(pageId)
    if (!date) {
        return ""
    }
    const two = (value) => String(value).padStart(2, "0")
    return `${two(date.getDate())}/${two(date.getMonth() + 1)}/${two(date.getFullYear() % 100)}`
}

class SearchField {
    constructor(onChange) {
        this.element = create("div", "search-field")
        this.shell = create("span", "pill-shell")
        this.icon = glyph("search", { color: tokens.palette.text_muted, size: 18 })
        this.input = create("input", "search-input")
        this.input.spellcheck = false
        this.clear = create("button", "search-clear", glyph("close", { color: tokens.palette.text_muted, size: 16 }))
        this.clear.hidden = true
        this.element.append(this.shell, this.icon, this.input, this.clear)
        this.typedCount = 0
        this.motion = new PillMotion(() => this.paint())
        this.motion.onElements = (shown, isInstant) => {
            if (isInstant) {
                hideTurned(this.icon)
                return
            }
            this.icon.style.opacity = ""
            revealElement(this.icon, shown)
            this.input.style.opacity = shown ? "1" : "0"
            if (shown && this.typedCount === 0) {
                this.typePrompt()
            }
        }
        this.input.style.opacity = "0"
        this.input.addEventListener("input", () => {
            onChange(this.input.value)
            this.paintClear()
        })
        this.input.addEventListener("focus", () => this.paint())
        this.input.addEventListener("blur", () => this.paint())
        this.input.addEventListener("keydown", (event) => {
            if (event.key === "Escape") {
                this.setValue("")
                onChange("")
                this.input.blur()
            }
            event.stopPropagation()
        })
        this.clear.addEventListener("click", () => {
            this.setValue("")
            onChange("")
        })
        this.isShown = false
    }

    typePrompt() {
        for (let count = 1; count <= searchPrompt.length; count += 1) {
            setTimeout(() => {
                this.typedCount = count
                this.input.placeholder = searchPrompt.slice(0, count)
            }, count * duration("type"))
        }
    }

    setValue(value) {
        if (this.input.value !== value) {
            this.input.value = value
        }
        this.paintClear()
    }

    paintClear() {
        const isEmpty = this.input.value.length === 0
        if (this.clear.hidden !== isEmpty) {
            this.clear.hidden = isEmpty
            if (!isEmpty) {
                popTogether(this.clear, true)
            }
        }
    }

    setShown(shown) {
        if (shown === this.isShown) {
            return
        }
        this.isShown = shown
        if (shown) {
            this.motion.enter()
        } else {
            this.input.blur()
            this.motion.leave()
        }
    }

    paint() {
        shapePillShell(this.shell, { width: 260, height: 48, isWide: true, scale: this.motion.shellScale, spread: this.motion.shellSpread })
        this.shell.style.borderColor = document.activeElement === this.input ? tokens.palette.accent : tokens.palette.border_control
        this.element.style.pointerEvents = this.motion.areElementsShown ? "auto" : "none"
        this.element.style.visibility = this.motion.isPresent ? "visible" : "hidden"
    }
}

export class TopBar {
    constructor(app) {
        this.app = app
        this.element = create("div", "top-bar")
        this.left = create("div", "top-bar-titles")
        this.folderPill = create("div", "folder-titles")
        this.folderLabel = microLabel("")
        this.folderTitleHost = create("div", "folder-title-host")
        this.folderShell = create("span", "pill-shell")
        this.folderPill.append(this.folderShell, this.folderTitleHost, this.folderLabel)
        this.isFolderShown = false
        this.folderMotion = new PillMotion(() => this.paintFolderPill())
        this.folderMotion.onElements = (shown, isInstant) => {
            for (const element of [this.folderTitleHost, this.folderLabel]) {
                if (isInstant) {
                    hideTurned(element)
                } else {
                    element.style.opacity = ""
                    revealElement(element, shown)
                }
            }
        }
        this.pageTitles = create("div", "page-titles")
        this.pageFolder = revealLabel(microLabel(""))
        this.pageName = inlineTitle({ title: "Note", size: bareTitleSize, isSweeping: false, onRename: (title) => this.renameNote(title) })
        this.pageNameReveal = revealLabel(this.pageName)
        this.pageDate = revealLabel(create("span", "page-date"))
        this.pageTitles.append(this.pageFolder, this.pageNameReveal, this.pageDate)
        this.left.append(this.folderPill, this.pageTitles)
        this.search = new SearchField((value) => {
            this.app.navigator.query = value
            this.app.refresh()
        })
        this.readOnly = microLabel("Read only", tokens.semantic.destructive)
        this.readOnly.classList.add("read-only-mark")
        this.readOnly.hidden = true
        this.searchHost = create("div", "search-host", this.search.element, this.readOnly)
        this.back = holdable(create("button", "back-button", glyph("back", { color: tokens.semantic.navigation })), { action: () => this.goBack() })
        this.back.setAttribute("aria-label", "Back")
        this.back.hidden = true
        this.settings = roundIconButton({ glyphName: "gear", label: "Settings", action: () => this.app.navigator.show({ kind: "settings" }) })
        this.controls = create("div", "top-bar-controls", this.back, this.settings)
        this.right = create("div", "top-bar-right", this.searchHost, this.controls)
        this.element.append(this.left, this.right)
        this.folderTitle = null
        this.isPage = null
        this.isPageShown = false
        window.addEventListener("keydown", (event) => {
            if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === "f" && !this.app.navigator.route.kind.startsWith("page")) {
                event.preventDefault()
                this.search.input.focus()
            }
        })
    }

    setFolderShown(shown) {
        if (shown === this.isFolderShown) {
            return
        }
        this.isFolderShown = shown
        if (shown) {
            this.folderMotion.enter()
        } else {
            this.folderMotion.leave()
        }
    }

    paintFolderPill() {
        shapePillShell(this.folderShell, { width: this.folderPill.offsetWidth, height: this.folderPill.offsetHeight, isWide: true, scale: this.folderMotion.shellScale, spread: this.folderMotion.shellSpread })
        this.folderPill.style.pointerEvents = this.folderMotion.areElementsShown ? "auto" : "none"
        this.folderPill.style.visibility = this.folderMotion.isPresent ? "visible" : "hidden"
    }

    renameNote(title) {
        const page = this.app.navigator.lastPage
        if (!page) {
            return
        }
        const trimmed = title.trim()
        this.app.library.updatePage(page.pageId, { title: trimmed ? title : null })
    }

    goBack() {
        const route = this.app.navigator.route
        if (route.kind === "notebook") {
            const parentId = this.app.library.parentOf(route.notebookId)
            this.app.navigator.go(parentId ? { kind: "notebook", notebookId: parentId } : { kind: "library" })
        } else if (route.kind === "page") {
            this.app.navigator.go({ kind: "notebook", notebookId: route.notebookId })
        }
    }

    update() {
        const library = this.app.library
        const navigator = this.app.navigator
        const route = navigator.route
        const isPage = route.kind === "page"
        const folderId = route.kind === "library" ? null : route.notebookId
        if (this.isPage !== isPage) {
            this.isPage = isPage
            this.pageTitles.style.pointerEvents = isPage ? "auto" : "none"
        }
        this.setFolderShown(!isPage && folderId !== null)
        this.search.setShown(!isPage)
        if (!isPage) {
            this.search.setValue(navigator.query)
        }
        const isReadOnly = isPage && navigator.lastPage && library.isReadOnly(navigator.lastPage.pageId)
        if (this.readOnly.hidden === Boolean(isReadOnly)) {
            this.readOnly.hidden = !isReadOnly
            if (isReadOnly) {
                popTogether(this.readOnly, true)
            }
        }
        const hasBack = folderId !== null
        if (hasBack && this.back.hidden) {
            this.back.hidden = false
            popTogether(this.back, true)
        } else if (!hasBack && !this.back.hidden && !this.backLeaving) {
            this.backLeaving = true
            popTogether(this.back, false).finished.then(() => {
                this.backLeaving = false
                if (this.app.navigator.route.kind === "library") {
                    this.back.hidden = true
                }
            })
        }
        if (!isPage && folderId) {
            this.folderLabel.textContent = library.folderSummary(folderId).toUpperCase()
            const title = library.notebook(folderId)?.title ?? ""
            if (!this.folderTitle) {
                this.folderTitle = inlineTitle({ title, size: folderTitleSize, onRename: (next) => {
                    const id = this.app.navigator.route.notebookId
                    if (next.trim() && id) {
                        library.updateNotebook(id, { title: next })
                    }
                } })
                this.folderTitleHost.replaceChildren(this.folderTitle)
            } else if (!this.folderTitle.isEditing()) {
                this.folderTitle.setTitle(title)
            }
            this.paintFolderPill()
        }
        const page = navigator.lastPage
        if (page) {
            const note = library.page(page.pageId)
            this.pageFolder.text.firstChild.textContent = (library.notebook(page.notebookId)?.title ?? "Folder").toUpperCase()
            if (!this.pageName.isEditing()) {
                this.pageName.setTitle(note ? library.noteTitle(note) : "Note")
            }
            this.pageDate.text.firstChild.textContent = createdText(page.pageId)
        }
        const isPageShown = isPage && navigator.isPageChromeShown && !navigator.isChromeLeaving
        if (isPageShown !== this.isPageShown) {
            this.isPageShown = isPageShown
            const stagger = duration("chrome_stagger")
            labelReveal(this.pageFolder, isPageShown)
            labelReveal(this.pageNameReveal, isPageShown, { delay: stagger })
            labelReveal(this.pageDate, isPageShown, { delay: stagger * 2 })
        }
        this.report()
    }

    report() {
        const isPage = this.isPage
        const frames = {}
        frames.title = layoutRect(isPage ? this.pageTitles : this.folderPill)
        if (!isPage) {
            frames.search = layoutRect(this.search.element)
        }
        frames.controls = layoutRect(this.controls)
        const bottom = Math.max(...Object.values(frames).map((frame) => frame.y + frame.height))
        this.app.setChromeLayout({ bottom, back: this.back.hidden ? null : layoutRect(this.back), frames })
    }
}

function layoutRect(element) {
    let x = 0
    let y = 0
    for (let current = element; current; current = current.offsetParent) {
        x += current.offsetLeft
        y += current.offsetTop
    }
    return { x: Math.round(x), y: Math.round(y), width: element.offsetWidth, height: element.offsetHeight }
}
