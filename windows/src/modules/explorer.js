import { create, microLabel, roundIconButton } from "./components.js"
import { slotsFromTokens } from "./menu.js"
import { animate, duration, fadeIn, fadeOut } from "./motion.js"
import { glyph, squircle, squircleRadius } from "./shapes.js"
import { tokens, withAlpha } from "./tokens.js"

const panelWidth = 380
const panelMargin = 12
const rowHeight = 40
const indentStep = 18
const dragTolerance = 8
const holdTolerance = 12
const hoverExpandMilliseconds = 600
const edgeScrollReach = 48
const edgeScrollSpeed = 12
const staggeredRows = 24

function folderLook(notebook) {
    return { color: notebook?.color ?? tokens.folders.default_color, icon: notebook?.icon ?? tokens.folders.default_icon }
}

function noteLook(page) {
    return { color: page?.color ?? tokens.palette.text_muted, icon: page?.icon ?? tokens.folders.note_icon }
}

function guideText(trail, isLast) {
    if (trail.length === 0) {
        return ""
    }
    return trail.slice(1).map((hasMore) => (hasMore ? "│ " : "  ")).join("") + (isLast ? "└─" : "├─")
}

export class Explorer {
    constructor(app) {
        this.app = app
        this.isOpen = false
        this.expanded = new Set()
        this.renaming = null
        this.moving = null
        this.drag = null
        this.rowElements = new Map()
        this.element = null
        window.addEventListener("keydown", (event) => {
            const isTyping = ["INPUT", "TEXTAREA"].includes(document.activeElement?.tagName) || document.activeElement?.isContentEditable
            if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === "e" && !isTyping) {
                event.preventDefault()
                this.toggle()
            } else if (event.key === "Escape" && this.isOpen && !this.app.menu.isPresented && !this.renaming) {
                if (this.moving) {
                    this.cancelMove()
                } else {
                    this.close()
                }
            }
        })
        window.addEventListener("resize", () => this.paintPanel())
    }

    toggle() {
        if (this.isOpen) {
            this.close()
        } else {
            this.open()
        }
    }

    currentFolderId() {
        const route = this.app.navigator.route
        return route.kind === "library" ? null : route.notebookId ?? null
    }

    currentPageId() {
        const route = this.app.navigator.route
        return route.kind === "page" ? route.pageId : null
    }

    revealCurrent() {
        let current = this.currentFolderId()
        const visited = new Set()
        while (current && !visited.has(current)) {
            visited.add(current)
            this.expanded.add(current)
            current = this.app.library.parentOf(current)
        }
    }

    open() {
        if (this.isOpen) {
            return
        }
        this.isOpen = true
        this.revealCurrent()
        this.leaving?.remove()
        this.leaving = null
        const scrim = create("div", "explorer-scrim")
        scrim.addEventListener("pointerdown", (event) => {
            event.preventDefault()
            this.close()
        })
        const panel = create("aside", "explorer-panel")
        const title = microLabel("Explorer")
        const depthChip = create("span", "explorer-depth-chip")
        const close = roundIconButton({ glyphName: "close", label: "Close explorer", action: () => this.close() })
        close.classList.add("explorer-close")
        const newFolder = this.headerCircle("folder_add", "New folder", tokens.semantic.create, () => this.createFolder(this.currentFolderId()))
        const newNote = this.headerCircle("note_add", "New note", tokens.semantic.create, () => this.createNote(this.currentFolderId()))
        const header = create("div", "explorer-header", create("div", "explorer-heading", title, depthChip), create("div", "explorer-actions", newFolder, newNote, close))
        const crumbs = create("div", "explorer-crumbs")
        const banner = create("div", "explorer-banner")
        banner.hidden = true
        const list = create("div", "explorer-list")
        list.addEventListener("pointerdown", (event) => this.listPointerDown(event))
        list.addEventListener("contextmenu", (event) => {
            event.preventDefault()
            const row = event.target.closest(".explorer-row")
            if (row && !this.drag) {
                this.showMenu(row.entry, [event.clientX, event.clientY])
            }
        })
        panel.append(header, crumbs, banner, list)
        this.element = create("div", "explorer", scrim, panel)
        this.parts = { scrim, panel, depthChip, crumbs, banner, list, newNote }
        this.app.overlayHost.prepend(this.element)
        this.paintPanel()
        this.render(true)
        fadeIn(scrim, duration("explorer_enter"))
        animate(panel, [{ transform: `translateX(calc(-100% - ${panelMargin * 2}px))` }, { transform: "translateX(0)" }], { milliseconds: duration("explorer_enter"), curveName: "back_out" })
        requestAnimationFrame(() => this.scrollToCurrent())
    }

    openMoving(target) {
        const library = this.app.library
        let folder = target.kind === "folder" ? library.parentOf(target.id) : library.page(target.id)?.notebook ?? null
        const visited = new Set()
        while (folder && !visited.has(folder)) {
            visited.add(folder)
            this.expanded.add(folder)
            folder = library.parentOf(folder)
        }
        const key = `${target.kind}-${target.id}`
        if (this.isOpen) {
            this.render(false)
        } else {
            this.open()
        }
        const entry = this.entries().find((candidate) => candidate.key === key)
        if (!entry) {
            return
        }
        this.beginMove(entry)
        requestAnimationFrame(() => this.rowElements.get(key)?.scrollIntoView({ block: "center" }))
    }

    close() {
        if (!this.isOpen) {
            return
        }
        this.isOpen = false
        this.finishRename(false)
        this.cancelDrag()
        this.moving = null
        const element = this.element
        const { scrim, panel } = this.parts
        this.element = null
        this.leaving = element
        element.style.pointerEvents = "none"
        fadeOut(scrim, duration("explorer_leave"))
        animate(panel, [{ transform: "translateX(0)" }, { transform: `translateX(calc(-100% - ${panelMargin * 2}px))` }], { milliseconds: duration("explorer_leave"), curveName: "power_two_in", fill: "forwards" }).finished.then(() => {
            element.remove()
            if (this.leaving === element) {
                this.leaving = null
            }
        })
    }

    headerCircle(glyphName, label, color, action) {
        const button = create("button", "explorer-circle", glyph(glyphName, { color, size: 16 }))
        button.setAttribute("aria-label", label)
        button.style.setProperty("--pill-tint", color)
        button.addEventListener("click", () => {
            if (!button.disabled) {
                action()
            }
        })
        return button
    }

    paintPanel() {
        if (!this.element) {
            return
        }
        const panel = this.parts.panel
        const width = Math.min(panelWidth, window.innerWidth - panelMargin * 2)
        panel.style.width = `${width}px`
        squircle(panel, { radius: squircleRadius.sheet, fill: tokens.palette.panel_solid, border: tokens.palette.border })
    }

    update() {
        if (!this.isOpen || this.renaming || this.drag) {
            return
        }
        this.render(false)
    }

    entries() {
        const library = this.app.library
        const rows = [{ key: "root", kind: "root", id: null, depth: 0, trail: [], isLast: true }]
        const walk = (parentId, depth, trail) => {
            const children = []
            const emitted = new Set()
            const folderGroups = library.groups(parentId).filter((group) => group.isFolders)
            for (const folder of library.folders(parentId)) {
                const group = folderGroups.find((candidate) => candidate.members.includes(folder.id))
                if (group) {
                    if (!emitted.has(group.id)) {
                        emitted.add(group.id)
                        children.push({ kind: "group", group, members: group.members.map((id) => ({ kind: "folder", id })) })
                    }
                    continue
                }
                children.push({ kind: "folder", id: folder.id })
            }
            if (parentId) {
                const noteGroups = library.groups(parentId).filter((group) => !group.isFolders)
                for (const page of library.pages(parentId)) {
                    const group = noteGroups.find((candidate) => candidate.members.includes(page.id))
                    if (group) {
                        if (!emitted.has(group.id)) {
                            emitted.add(group.id)
                            children.push({ kind: "group", group, members: group.members.map((id) => ({ kind: "note", id })) })
                        }
                        continue
                    }
                    children.push({ kind: "note", id: page.id })
                }
            }
            const emit = (child, childDepth, childTrail, isLast) => {
                if (child.kind === "group") {
                    rows.push({ key: `group-${child.group.id}`, kind: "group", id: child.group.id, title: child.group.title, parentId, depth: childDepth, trail: childTrail, isLast })
                    child.members.forEach((member, index) => emit(member, childDepth + 1, [...childTrail, !isLast], index === child.members.length - 1))
                    return
                }
                if (child.kind === "folder") {
                    rows.push({ key: `folder-${child.id}`, kind: "folder", id: child.id, parentId, depth: childDepth, trail: childTrail, isLast })
                    if (this.expanded.has(child.id)) {
                        walk(child.id, childDepth + 1, [...childTrail, !isLast])
                    }
                    return
                }
                rows.push({ key: `note-${child.id}`, kind: "note", id: child.id, parentId, depth: childDepth, trail: childTrail, isLast })
            }
            children.forEach((child, index) => emit(child, depth, trail, index === children.length - 1))
        }
        walk(null, 1, [false])
        return rows
    }

    render(isEntering) {
        const library = this.app.library
        const { depthChip, crumbs, banner, list, newNote } = this.parts
        const folderId = this.currentFolderId()
        const segments = folderId ? library.depth(folderId) : []
        depthChip.textContent = `DEPTH ${segments.length}`
        crumbs.replaceChildren(this.crumb("Library", null, null, segments.length === 0))
        segments.forEach((segment, index) => {
            crumbs.append(create("span", "explorer-crumb-divider", index === 0 ? "›" : "/"))
            crumbs.append(this.crumb(segment.title, segment.id, segment.group, index === segments.length - 1))
        })
        newNote.disabled = !folderId
        newNote.classList.toggle("is-disabled", !folderId)
        this.paintBanner(banner)
        const scroll = list.scrollTop
        const rows = this.entries()
        list.replaceChildren()
        this.rowElements.clear()
        rows.forEach((entry, index) => {
            const row = this.makeRow(entry)
            list.append(row)
            this.rowElements.set(entry.key, row)
            if (isEntering && index < staggeredRows) {
                animate(row, [{ opacity: 0, transform: "translateX(-24px)" }, { opacity: 1, transform: "translateX(0)" }], { milliseconds: duration("state"), curveName: "power_two_out", delay: duration("rise_delay") + index * duration("explorer_row_stagger") })
            }
        })
        list.scrollTop = scroll
    }

    crumb(title, notebookId, group, isCurrent) {
        const button = create("button", "explorer-crumb")
        if (group) {
            button.append(create("span", "explorer-crumb-group", `${group.toUpperCase()} -`))
        }
        button.append(create("span", "explorer-crumb-title", title))
        button.classList.toggle("is-current", isCurrent)
        button.addEventListener("click", () => this.go(notebookId))
        return button
    }

    paintBanner(banner) {
        if (!this.moving) {
            banner.hidden = true
            return
        }
        banner.hidden = false
        const cancel = create("button", "explorer-pill is-small", glyph("close", { color: tokens.palette.text_body, size: 14 }), create("span", "explorer-pill-title", "CANCEL"))
        cancel.addEventListener("click", () => this.cancelMove())
        banner.replaceChildren(glyph("move", { color: tokens.semantic.navigation, size: 16 }), create("span", "explorer-banner-text", `MOVE ${this.titleOf(this.moving).toUpperCase()} TO …`), cancel)
    }

    titleOf(entry) {
        const library = this.app.library
        if (entry.kind === "folder") {
            return library.notebook(entry.id)?.title ?? "Folder"
        }
        if (entry.kind === "note") {
            const page = library.page(entry.id)
            return page ? library.noteTitle(page) : "Note"
        }
        if (entry.kind === "group") {
            return entry.title
        }
        return "Library"
    }

    canDrop(entry, target) {
        if (!entry || !target) {
            return false
        }
        const library = this.app.library
        if (entry.kind === "folder") {
            if (target.kind === "root") {
                return library.parentOf(entry.id) !== null
            }
            return target.kind === "folder" && library.canMoveNotebook(entry.id, target.id) && library.parentOf(entry.id) !== target.id
        }
        if (entry.kind === "note") {
            return target.kind === "folder" && library.page(entry.id)?.notebook !== target.id && !library.isReadOnly(entry.id)
        }
        return false
    }

    makeRow(entry) {
        const library = this.app.library
        const row = create("div", `explorer-row is-${entry.kind}`)
        row.entry = entry
        row.style.height = `${rowHeight}px`
        const guides = create("span", "explorer-guides", guideText(entry.trail, entry.isLast))
        const chevron = create("button", "explorer-chevron")
        chevron.setAttribute("aria-label", "Expand")
        const icon = create("span", "explorer-icon")
        const title = create("span", "explorer-title", this.titleOf(entry))
        const meta = create("span", "explorer-meta")
        row.append(guides, chevron, icon, title, meta)
        row.titleElement = title
        const folderId = this.currentFolderId()
        if (entry.kind === "root") {
            icon.append(glyph("home", { color: tokens.palette.text_body, size: 18 }))
            title.textContent = "LIBRARY"
            title.classList.add("is-caps")
            meta.textContent = String(library.folders(null).length)
            row.classList.toggle("is-current", folderId === null)
            chevron.classList.add("is-empty")
        } else if (entry.kind === "group") {
            icon.append(glyph("stack", { color: tokens.palette.text_muted, size: 16 }))
            title.classList.add("is-caps")
            chevron.classList.add("is-empty")
        } else if (entry.kind === "folder") {
            const notebook = library.notebook(entry.id)
            const look = folderLook(notebook)
            icon.append(glyph(look.icon, { color: look.color, size: 18 }))
            const hasChildren = library.folders(entry.id).length > 0 || library.pages(entry.id).length > 0
            chevron.append(glyph("chevron", { color: tokens.palette.text_muted, size: 14 }))
            chevron.classList.toggle("is-empty", !hasChildren)
            chevron.classList.toggle("is-open", this.expanded.has(entry.id))
            chevron.addEventListener("click", (event) => {
                event.stopPropagation()
                this.toggleExpanded(entry.id)
            })
            meta.textContent = library.folderSummary(entry.id).toUpperCase()
            row.classList.toggle("is-current", folderId === entry.id && !this.currentPageId())
            row.classList.toggle("is-on-path", Boolean(folderId) && library.isInside(folderId, entry.id) && folderId !== entry.id)
        } else {
            const page = library.page(entry.id)
            const look = noteLook(page)
            icon.append(glyph(look.icon, { color: look.color, size: 16 }))
            chevron.classList.add("is-empty")
            row.classList.toggle("is-current", this.currentPageId() === entry.id)
            row.classList.toggle("is-read-only", library.isReadOnly(entry.id))
        }
        if (this.moving) {
            const isSelf = this.moving.kind === entry.kind && this.moving.id === entry.id
            row.classList.toggle("is-moving", isSelf)
            row.classList.toggle("is-drop-target", this.canDrop(this.moving, entry))
            row.classList.toggle("is-dimmed", !isSelf && !this.canDrop(this.moving, entry))
        }
        row.style.setProperty("--depth", String(entry.depth))
        return row
    }

    toggleExpanded(notebookId) {
        if (this.expanded.has(notebookId)) {
            this.expanded.delete(notebookId)
        } else {
            this.expanded.add(notebookId)
        }
        this.render(false)
        const row = this.rowElements.get(`folder-${notebookId}`)
        let next = row?.nextElementSibling
        let index = 0
        while (next && next.entry.depth > row.entry.depth) {
            animate(next, [{ opacity: 0, transform: "translateX(16px)" }, { opacity: 1, transform: "translateX(0)" }], { milliseconds: duration("state"), curveName: "power_two_out", delay: index * duration("explorer_row_stagger") })
            next = next.nextElementSibling
            index += 1
        }
    }

    scrollToCurrent() {
        const row = this.parts?.list.querySelector(".explorer-row.is-current")
        row?.scrollIntoView({ block: "nearest" })
    }

    go(notebookId) {
        this.app.navigator.go(notebookId ? { kind: "notebook", notebookId } : { kind: "library" })
        if (notebookId) {
            this.expanded.add(notebookId)
        }
    }

    activateRow(row) {
        const entry = row.entry
        if (this.moving) {
            if (this.canDrop(this.moving, entry)) {
                this.performMove(this.moving, entry)
            }
            return
        }
        if (entry.kind === "root") {
            this.go(null)
        } else if (entry.kind === "folder") {
            this.go(entry.id)
        } else if (entry.kind === "note") {
            const page = this.app.library.page(entry.id)
            if (page) {
                this.close()
                this.app.navigator.go({ kind: "page", notebookId: page.notebook, pageId: page.id })
            }
        }
    }

    listPointerDown(event) {
        const row = event.target.closest(".explorer-row")
        if (!row || event.button > 0 || this.renaming || event.target.closest(".explorer-chevron:not(.is-empty)")) {
            return
        }
        const entry = row.entry
        const isMouse = event.pointerType === "mouse"
        const isMovable = entry.kind === "folder" || entry.kind === "note"
        const pointerId = event.pointerId
        const start = [event.clientX, event.clientY]
        let holdPoint = null
        let isDone = false
        const holdTimer = isMouse ? null : setTimeout(() => {
            holdPoint = [...start]
            this.showMenu(entry, start)
        }, duration("menu_hold"))
        const finish = () => {
            isDone = true
            clearTimeout(holdTimer)
            window.removeEventListener("pointermove", move)
            window.removeEventListener("pointerup", end)
            window.removeEventListener("pointercancel", end)
        }
        const move = (moveEvent) => {
            if (moveEvent.pointerId !== pointerId || isDone) {
                return
            }
            const point = [moveEvent.clientX, moveEvent.clientY]
            if (this.drag) {
                this.dragTo(point)
                return
            }
            if (holdPoint) {
                if (isMovable && Math.hypot(point[0] - holdPoint[0], point[1] - holdPoint[1]) > holdTolerance) {
                    this.app.menu.dismiss()
                    this.beginDrag(row, point)
                }
                return
            }
            if (Math.hypot(point[0] - start[0], point[1] - start[1]) > dragTolerance) {
                clearTimeout(holdTimer)
                if (isMouse && isMovable) {
                    this.beginDrag(row, point)
                } else if (!isMouse) {
                    finish()
                }
            }
        }
        const end = (endEvent) => {
            if (endEvent.pointerId !== pointerId) {
                return
            }
            finish()
            if (this.drag) {
                this.endDrag(endEvent.type === "pointerup")
                return
            }
            if (endEvent.type === "pointerup" && !holdPoint) {
                this.activateRow(row)
            }
        }
        window.addEventListener("pointermove", move)
        window.addEventListener("pointerup", end)
        window.addEventListener("pointercancel", end)
    }

    beginDrag(row, point) {
        const rect = row.getBoundingClientRect()
        const ghost = row.cloneNode(true)
        ghost.classList.add("explorer-ghost")
        ghost.style.width = `${rect.width}px`
        ghost.style.left = `${rect.left}px`
        ghost.style.top = `${rect.top}px`
        document.body.append(ghost)
        animate(ghost, [{ scale: "1" }, { scale: String(tokens.motion.scales.held) }], { milliseconds: duration("state"), curveName: "back_out", fill: "forwards" })
        row.classList.add("is-lifted")
        this.drag = { entry: row.entry, row, ghost, offset: [point[0] - rect.left, point[1] - rect.top], target: null, hoverTimer: null, point }
        this.scrollLoop()
    }

    dragTo(point) {
        const drag = this.drag
        drag.point = point
        drag.ghost.style.left = `${point[0] - drag.offset[0]}px`
        drag.ghost.style.top = `${point[1] - drag.offset[1]}px`
        drag.ghost.style.visibility = "hidden"
        const under = document.elementFromPoint(point[0], point[1])?.closest(".explorer-row")
        drag.ghost.style.visibility = ""
        const target = under && this.canDrop(drag.entry, under.entry) ? under : null
        if (target !== drag.target) {
            drag.target?.classList.remove("is-drop-hover")
            target?.classList.add("is-drop-hover")
            drag.target = target
            clearTimeout(drag.hoverTimer)
            if (target?.entry.kind === "folder" && !this.expanded.has(target.entry.id)) {
                const notebookId = target.entry.id
                drag.hoverTimer = setTimeout(() => {
                    if (this.drag?.target?.entry.id === notebookId) {
                        this.expanded.add(notebookId)
                        this.renderDuringDrag()
                    }
                }, hoverExpandMilliseconds)
            }
        }
    }

    renderDuringDrag() {
        const drag = this.drag
        this.drag = null
        this.render(false)
        this.drag = drag
        drag.row = this.rowElements.get(drag.entry.kind === "folder" ? `folder-${drag.entry.id}` : `note-${drag.entry.id}`) ?? drag.row
        drag.row.classList.add("is-lifted")
        drag.target = null
        this.dragTo(drag.point)
    }

    scrollLoop() {
        const drag = this.drag
        if (!drag || !this.parts) {
            return
        }
        const list = this.parts.list
        const rect = list.getBoundingClientRect()
        const y = drag.point[1]
        if (y < rect.top + edgeScrollReach) {
            list.scrollTop -= edgeScrollSpeed * (1 - Math.max(0, y - rect.top) / edgeScrollReach)
        } else if (y > rect.bottom - edgeScrollReach) {
            list.scrollTop += edgeScrollSpeed * (1 - Math.max(0, rect.bottom - y) / edgeScrollReach)
        }
        requestAnimationFrame(() => this.scrollLoop())
    }

    endDrag(isDrop) {
        const drag = this.drag
        if (!drag) {
            return
        }
        this.drag = null
        clearTimeout(drag.hoverTimer)
        drag.row.classList.remove("is-lifted")
        const target = isDrop ? drag.target : null
        if (target) {
            const rect = target.getBoundingClientRect()
            animate(drag.ghost, [{ opacity: 1, transform: "scale(1)" }, { opacity: 0, transform: `translate(${rect.left + 24 - drag.ghost.offsetLeft}px, ${rect.top - drag.ghost.offsetTop}px) scale(0.4)` }], { milliseconds: duration("state"), curveName: "power_two_in", fill: "forwards" }).finished.then(() => drag.ghost.remove())
            this.performMove(drag.entry, target.entry)
        } else {
            const rect = drag.row.getBoundingClientRect()
            animate(drag.ghost, [{ left: drag.ghost.style.left, top: drag.ghost.style.top }, { left: `${rect.left}px`, top: `${rect.top}px` }], { milliseconds: duration("state"), curveName: "power_two_out", fill: "forwards" }).finished.then(() => drag.ghost.remove())
            this.render(false)
        }
    }

    cancelDrag() {
        if (!this.drag) {
            return
        }
        this.drag.ghost.remove()
        clearTimeout(this.drag.hoverTimer)
        this.drag = null
    }

    performMove(entry, target) {
        const library = this.app.library
        const navigator = this.app.navigator
        this.moving = null
        if (entry.kind === "folder") {
            library.moveNotebook(entry.id, target.kind === "root" ? null : target.id)
            if (target.kind === "folder") {
                this.expanded.add(target.id)
            }
        } else if (entry.kind === "note") {
            const movedId = library.movePage(entry.id, target.id)
            this.expanded.add(target.id)
            const route = navigator.route
            if (movedId && route.kind === "page" && route.pageId === entry.id) {
                navigator.go({ kind: "page", notebookId: target.id, pageId: movedId })
            }
        }
        this.render(false)
        const key = entry.kind === "folder" ? `folder-${entry.id}` : null
        const landed = key ? this.rowElements.get(key) : this.rowElements.get(`folder-${target.id}`)
        if (landed) {
            landed.scrollIntoView({ block: "nearest" })
            animate(landed, [{ background: withAlpha(tokens.palette.accent, 0.22) }, { background: "transparent" }], { milliseconds: duration("sweep_retract"), curveName: "power_two_out" })
        }
    }

    beginMove(entry) {
        this.moving = entry
        this.render(false)
    }

    cancelMove() {
        this.moving = null
        this.render(false)
    }

    showMenu(entry, point) {
        const library = this.app.library
        const titles = { rename: "Rename", new_folder: "New folder", new_note: "New note", move: "Move", delete_notebook: "Delete", delete_page: "Delete" }
        let definitions
        if (entry.kind === "root") {
            definitions = tokens.menus.explorer_root
        } else if (entry.kind === "folder") {
            definitions = tokens.menus.explorer_folder
        } else if (entry.kind === "note") {
            definitions = tokens.menus.explorer_note
        } else {
            return
        }
        const isReadOnly = entry.kind === "note" && library.isReadOnly(entry.id)
        const slots = slotsFromTokens(definitions, {
            title: (action) => titles[action] ?? action,
            isEnabled: (action) => !isReadOnly || action === "delete_page",
            perform: (action) => this.perform(action, entry),
        })
        this.app.menu.present(slots, point, this.titleOf(entry))
    }

    perform(action, entry) {
        const library = this.app.library
        switch (action) {
        case "rename":
            this.beginRename(entry)
            break
        case "new_folder":
            this.createFolder(entry.kind === "folder" ? entry.id : null)
            break
        case "new_note":
            this.createNote(entry.id)
            break
        case "move":
            this.beginMove(entry)
            break
        case "delete_notebook": {
            const parentId = library.parentOf(entry.id)
            const folderId = this.currentFolderId()
            const isInside = folderId && library.isInside(folderId, entry.id)
            library.deleteNotebook(entry.id)
            this.expanded.delete(entry.id)
            if (isInside) {
                this.app.navigator.go(parentId ? { kind: "notebook", notebookId: parentId } : { kind: "library" })
            }
            break
        }
        case "delete_page": {
            const page = library.page(entry.id)
            library.deletePage(entry.id)
            if (page && this.currentPageId() === entry.id) {
                this.app.navigator.go({ kind: "notebook", notebookId: page.notebook })
            }
            break
        }
        default:
            break
        }
    }

    createFolder(parentId) {
        const notebook = this.app.library.createNotebook("New folder", parentId)
        if (parentId) {
            this.expanded.add(parentId)
        }
        this.render(false)
        this.beginRename({ kind: "folder", id: notebook.id })
    }

    createNote(notebookId) {
        if (!notebookId || !this.app.library.notebook(notebookId)) {
            return
        }
        const page = this.app.library.createPage(notebookId)
        this.expanded.add(notebookId)
        this.render(false)
        if (page) {
            this.beginRename({ kind: "note", id: page.id })
        }
    }

    beginRename(entry) {
        this.finishRename(true)
        const key = `${entry.kind}-${entry.id}`
        const row = this.rowElements.get(key)
        if (!row) {
            return
        }
        row.scrollIntoView({ block: "nearest" })
        const input = create("input", "explorer-rename")
        input.value = this.titleOf(row.entry)
        input.spellcheck = false
        row.titleElement.replaceWith(input)
        row.classList.add("is-renaming")
        this.renaming = { entry: row.entry, input }
        input.addEventListener("keydown", (event) => {
            event.stopPropagation()
            if (event.key === "Enter") {
                event.preventDefault()
                this.finishRename(true)
            } else if (event.key === "Escape") {
                event.preventDefault()
                this.finishRename(false)
            }
        })
        input.addEventListener("blur", () => this.finishRename(true))
        input.addEventListener("pointerdown", (event) => event.stopPropagation())
        requestAnimationFrame(() => {
            input.focus()
            input.select()
        })
    }

    finishRename(isCommitted) {
        const renaming = this.renaming
        if (!renaming) {
            return
        }
        this.renaming = null
        const value = renaming.input.value.trim()
        const library = this.app.library
        if (isCommitted && value) {
            if (renaming.entry.kind === "folder") {
                library.updateNotebook(renaming.entry.id, { title: value })
            } else if (renaming.entry.kind === "note") {
                library.updatePage(renaming.entry.id, { title: value })
            }
        }
        if (this.isOpen) {
            this.render(false)
        }
    }
}
