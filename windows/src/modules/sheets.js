import { create, field, linkButton, microLabel, pressable, segmented, setEnabled, slabButton } from "./components.js"
import { colorPanel, sizeSlider, swatchButton, wheelButton } from "./controls.js"
import { exportNote } from "./exports.js"
import { folderLook, noteLook } from "./grid.js"
import { readPdf } from "./imports.js"
import { animate, curve, duration } from "./motion.js"
import { popTogether } from "./pill.js"
import * as preferences from "./preferences.js"
import { glyph, squircle, squircleRadius } from "./shapes.js"
import { syncSettings } from "./sync.js"
import { tokens } from "./tokens.js"

const armedMilliseconds = 2400

function sheetPanel(heading, ...content) {
    const panel = create("div", "sheet-panel", microLabel(heading), ...content)
    squircle(panel, { radius: squircleRadius.sheet, fill: tokens.palette.panel_solid, border: tokens.palette.border_strong })
    return panel
}

function pickFile(accept) {
    return new Promise((resolve) => {
        const input = create("input")
        input.type = "file"
        input.accept = accept
        input.addEventListener("change", () => resolve(input.files?.[0] ?? null))
        input.addEventListener("cancel", () => resolve(null))
        input.click()
    })
}

function selectAllOnFocus(input) {
    input.addEventListener("focus", () => requestAnimationFrame(() => input.select()))
}

export function isNaming(request) {
    return ["newFolder", "renameFolder", "renameNote", "newNote", "pickGroup", "renameGroup"].includes(request.kind)
}

function nameSheet({ heading, initial, confirmTitle, confirmColor, selectsAll = false, confirm }) {
    const title = field({ placeholder: "Name", value: initial })
    const submit = () => {
        const trimmed = title.input.value.trim()
        if (trimmed) {
            confirm(trimmed)
        }
    }
    const button = slabButton(confirmTitle, confirmColor, submit)
    const refresh = () => setEnabled(button, title.input.value.trim().length > 0)
    title.input.addEventListener("input", refresh)
    title.input.addEventListener("keydown", (event) => {
        if (event.key === "Enter") {
            submit()
        }
    })
    if (selectsAll) {
        selectAllOnFocus(title.input)
    }
    refresh()
    const panel = sheetPanel(heading, title, button)
    panel.focusTarget = title.input
    return panel
}

function groupSheet(app, request) {
    const memberId = request.target.id
    const isFolders = request.target.kind === "folder"
    const groups = preferences.groups(request.parentId).filter((group) => group.isFolders === isFolders)
    const rows = create("div", "sheet-rows")
    for (const group of groups) {
        const row = create("button", "sheet-row", glyph("stack", { color: tokens.palette.accent, size: 18 }), create("span", "sheet-row-title", group.title), create("span", "sheet-row-spacer"), microLabel(String(group.members.length)))
        pressable(row)
        row.addEventListener("click", () => {
            preferences.addToGroup(memberId, group.id, request.parentId)
            app.navigator.show(null)
        })
        rows.append(row)
    }
    const title = field({ placeholder: "New group" })
    const create_ = () => {
        const trimmed = title.input.value.trim()
        if (!trimmed) {
            return
        }
        preferences.createGroup(trimmed, isFolders, memberId, request.parentId)
        app.navigator.show(null)
    }
    const button = slabButton("Create group", tokens.semantic.create, create_)
    title.input.addEventListener("input", () => setEnabled(button, title.input.value.trim().length > 0))
    title.input.addEventListener("keydown", (event) => {
        if (event.key === "Enter") {
            create_()
        }
    })
    setEnabled(button, false)
    const panel = sheetPanel("Add to group", ...(groups.length ? [rows] : []), title, button)
    panel.focusTarget = groups.length ? null : title.input
    return panel
}

function appearanceSheet(app, request) {
    const library = app.library
    const target = request.target
    const header = create("div", "appearance-header")
    const preview = create("span", "appearance-preview")
    const name = create("span", "appearance-name")
    header.append(preview, name)
    const swatches = create("div", "appearance-swatches")
    const icons = create("div", "appearance-icons")
    const details = () => {
        if (target.kind === "folder") {
            const notebook = library.notebook(target.id)
            return notebook ? { title: notebook.title, ...folderLook(notebook) } : null
        }
        const page = library.page(target.id)
        return page ? { title: library.noteTitle(page), ...noteLook(page) } : null
    }
    const apply = (changes) => {
        if (target.kind === "folder") {
            library.updateNotebook(target.id, changes)
        } else {
            library.updatePage(target.id, changes)
        }
        render()
    }
    const colorButtons = tokens.folders.colors.map((color) => {
        const swatch = swatchButton({ color, orientation: "horizontal", onSelect: () => apply({ color }) })
        swatches.append(swatch)
        return { color, swatch }
    })
    const iconButtons = tokens.folders.icons.map((icon) => {
        const button = create("button", "appearance-icon")
        pressable(button)
        button.addEventListener("click", () => apply({ icon }))
        icons.append(button)
        return { icon, button }
    })
    const render = () => {
        const current = details()
        if (!current) {
            return
        }
        preview.replaceChildren(glyph(current.icon, { color: current.color, size: 28 }))
        name.textContent = current.title
        for (const { color, swatch } of colorButtons) {
            swatch.update({ color, isSelected: color.toUpperCase() === current.color.toUpperCase() })
        }
        for (const { icon, button } of iconButtons) {
            const isSelected = icon === current.icon
            button.replaceChildren(glyph(icon, { color: isSelected ? current.color : tokens.palette.text_muted }))
            button.style.borderColor = isSelected ? current.color : "transparent"
        }
    }
    render()
    return sheetPanel("Icon & colour", header, swatches, icons, slabButton("Done", tokens.semantic.create, () => app.navigator.show(null)))
}

function moveSheet(app, request) {
    const library = app.library
    const target = request.target
    const tree = (parentId, depth) => library.folders(parentId).flatMap((folder) => [{ id: folder.id, notebook: folder, depth }, ...tree(folder.id, depth + 1)])
    const rows = target.kind === "folder" ? [{ id: "root", notebook: null, depth: 0 }, ...tree(null, 0)] : tree(null, 0)
    const list = create("div", "sheet-rows is-scrolling")
    for (const row of rows) {
        let isCurrent
        let isEnabled
        if (target.kind === "folder") {
            const destination = row.notebook?.id ?? null
            isCurrent = library.parentOf(target.id) === destination
            isEnabled = !isCurrent && library.canMoveNotebook(target.id, destination)
        } else {
            isCurrent = library.page(target.id)?.notebook === row.notebook?.id
            isEnabled = !isCurrent && Boolean(row.notebook)
        }
        const look = folderLook(row.notebook)
        const button = create("button", "sheet-row",
            glyph(row.notebook ? look.icon : "home", { color: row.notebook ? look.color : tokens.semantic.navigation, size: 18 }),
            create("span", "sheet-row-title", row.notebook?.title ?? "Folders (top level)"),
            create("span", "sheet-row-spacer"),
            isCurrent ? microLabel("Here") : null)
        button.style.paddingLeft = `${16 + row.depth * 22}px`
        setEnabled(button, isEnabled)
        pressable(button)
        button.addEventListener("click", () => {
            if (!isEnabled) {
                return
            }
            if (target.kind === "folder") {
                library.moveNotebook(target.id, row.notebook?.id ?? null)
            } else if (row.notebook) {
                library.movePage(target.id, row.notebook.id)
            }
            app.navigator.show(null)
        })
        list.append(button)
    }
    return sheetPanel("Move to", list)
}

function newNoteSheet(app, request) {
    const library = app.library
    const title = field({ placeholder: "Name", value: `Note ${library.pages(request.notebookId).length + 1}` })
    selectAllOnFocus(title.input)
    let isPdf = false
    let document_ = null
    const fileTitle = create("span", "pdf-choice-title", "Choose PDF")
    const fileDetail = microLabel("No file chosen")
    const choose = create("button", "pdf-choice", glyph("note_add", { color: tokens.semantic.import }), create("div", "pdf-choice-text", fileTitle, fileDetail))
    choose.hidden = true
    pressable(choose)
    const createButton = slabButton("Create", tokens.semantic.create, () => submit())
    const refresh = () => setEnabled(createButton, title.input.value.trim().length > 0 && (!isPdf || Boolean(document_)))
    const pick = async () => {
        const file = await pickFile("application/pdf,.pdf")
        if (!file) {
            return
        }
        fileTitle.textContent = file.name
        try {
            document_ = await readPdf(file)
            fileDetail.textContent = `${document_.pages.length} PAGE${document_.pages.length === 1 ? "" : "S"}`
            fileDetail.style.color = ""
            const trimmed = title.input.value.trim()
            if (!trimmed || trimmed.startsWith("Note ")) {
                title.input.value = file.name.replace(/\.pdf$/i, "")
            }
        } catch {
            document_ = null
            fileDetail.textContent = "NOT A READABLE PDF"
            fileDetail.style.color = tokens.semantic.destructive
        }
        refresh()
    }
    choose.addEventListener("click", pick)
    const kind = segmented([{ value: false, title: "Blank" }, { value: true, title: "PDF" }], false, (value) => {
        isPdf = value
        choose.hidden = !value
        if (value) {
            animate(choose, [{ opacity: 0 }, { opacity: 1 }], { milliseconds: duration("state"), curveName: "power_two_out" })
            if (!document_) {
                pick()
            }
        }
        refresh()
    })
    const submit = () => {
        const trimmed = title.input.value.trim()
        if (!trimmed || (isPdf && !document_)) {
            return
        }
        const page = library.createPage(request.notebookId, { title: trimmed, pdf: isPdf ? document_ : null })
        app.navigator.show(null)
        app.navigator.go({ kind: "page", notebookId: request.notebookId, pageId: page.id })
    }
    title.input.addEventListener("input", refresh)
    title.input.addEventListener("keydown", (event) => {
        if (event.key === "Enter") {
            submit()
        }
    })
    refresh()
    const panel = sheetPanel("New note", title, kind, choose, createButton)
    panel.focusTarget = title.input
    return panel
}

function settingsModule(label, detail, ...content) {
    const header = create("div", "settings-module-header", microLabel(label))
    if (detail !== null) {
        const detailLabel = microLabel(detail, tokens.palette.text_muted)
        header.append(detailLabel)
        header.detail = detailLabel
    }
    const module = create("div", "settings-module", header, ...content)
    module.header = header
    squircle(module, { radius: squircleRadius.panel, fill: tokens.palette.panel_solid, border: tokens.palette.border })
    return module
}

function settingsSlider(title, share, caption, onChange) {
    const value = create("span", "settings-slider-value", caption)
    const slider = sizeSlider({ share, length: 220, onChange: (next) => value.textContent = onChange(next) })
    return create("div", "settings-slider", slider, create("div", "settings-slider-text", microLabel(title, tokens.palette.text_muted), value))
}

function rangeShare(value, range) {
    return (value - range[0]) / (range[1] - range[0])
}

function rangeValue(share, range) {
    return range[0] + (range[1] - range[0]) * share
}

function settingsSheet(app) {
    const library = app.library
    const route = app.navigator.route
    const pageContext = route.kind === "page" ? route : null
    const page = () => (pageContext ? library.page(pageContext.pageId) : null)
    const isPageEditable = () => Boolean(pageContext && page() && !library.isReadOnly(pageContext.pageId))

    const asciiColors = tokens.background.colors
    let isWheelOpen = false
    const asciiToggle = segmented([{ value: true, title: "On" }, { value: false, title: "Off" }], preferences.showsAsciiBackground(), (value) => preferences.setShowsAsciiBackground(value))
    const asciiSwatchRow = create("div", "settings-swatches")
    const wheel = wheelButton({ orientation: "horizontal", action: () => {
        isWheelOpen = !isWheelOpen
        renderAscii(true)
    } })
    asciiSwatchRow.append(wheel)
    const asciiSwatches = asciiColors.map((color) => {
        const swatch = swatchButton({ color, orientation: "horizontal", onSelect: () => {
            preferences.setAsciiBackgroundColor(color)
            renderAscii(false)
        } })
        asciiSwatchRow.append(swatch)
        return { color, swatch }
    })
    const asciiPanelHost = create("div", "settings-panel-host")
    let asciiPanel = null
    const opacityRange = tokens.background.opacity_range
    const opacity = settingsSlider("Opacity", rangeShare(preferences.asciiBackgroundOpacity(), opacityRange), `${Math.round(preferences.asciiBackgroundOpacity() * 100)}%`, (share) => {
        preferences.setAsciiBackgroundOpacity(rangeValue(share, opacityRange))
        return `${Math.round(preferences.asciiBackgroundOpacity() * 100)}%`
    })
    const motionToggle = segmented([{ value: false, title: "Still" }, { value: true, title: "Moving" }], preferences.isAsciiBackgroundMoving(), (value) => {
        preferences.setAsciiBackgroundMoving(value)
        renderAscii(true)
    })
    const canvasToggle = segmented([{ value: true, title: "Both" }, { value: false, title: "Exclude canvas" }], preferences.doesAsciiBackgroundMoveInCanvas(), (value) => preferences.setAsciiBackgroundMovesInCanvas(value))
    const renderAscii = (isAnimated) => {
        const current = preferences.asciiBackgroundColor().toUpperCase()
        const isCustom = !asciiColors.map((color) => color.toUpperCase()).includes(current)
        wheel.update({ isOpen: isWheelOpen || isCustom })
        for (const { color, swatch } of asciiSwatches) {
            swatch.update({ color, isSelected: color.toUpperCase() === current })
        }
        if (isWheelOpen && !asciiPanel) {
            asciiPanel = colorPanel({ color: current, onChange: (hex) => preferences.setAsciiBackgroundColor(hex) })
            asciiPanelHost.append(asciiPanel)
            if (isAnimated) {
                popTogether(asciiPanel, true)
            }
        } else if (!isWheelOpen && asciiPanel) {
            const old = asciiPanel
            asciiPanel = null
            popTogether(old, false).finished.then(() => old.remove())
        }
        const isMoving = preferences.isAsciiBackgroundMoving()
        if (isMoving && canvasToggle.hidden) {
            canvasToggle.hidden = false
            if (isAnimated) {
                popTogether(canvasToggle, true)
            }
        } else if (!isMoving && !canvasToggle.hidden) {
            if (isAnimated) {
                popTogether(canvasToggle, false).finished.then(() => {
                    canvasToggle.hidden = !preferences.isAsciiBackgroundMoving()
                })
            } else {
                canvasToggle.hidden = true
            }
        }
    }
    canvasToggle.hidden = !preferences.isAsciiBackgroundMoving()
    renderAscii(false)
    const asciiModule = settingsModule("ASCII", null, asciiToggle, asciiSwatchRow, asciiPanelHost, opacity, motionToggle, canvasToggle)

    const importFailure = microLabel("", tokens.semantic.destructive)
    importFailure.hidden = true
    const importButton = linkButton({ glyphName: "import", title: "Import", tint: tokens.semantic.import, isEnabled: isPageEditable(), action: async () => {
        const file = await pickFile("application/pdf,.pdf")
        if (!file || !pageContext) {
            return
        }
        try {
            const imported = await readPdf(file)
            library.appendDocument(imported, pageContext.pageId)
            importFailure.hidden = true
            app.navigator.show(null)
        } catch {
            importFailure.textContent = "NOT A READABLE PDF"
            importFailure.hidden = false
        }
    } })
    const exportButton = linkButton({ glyphName: "export", title: "Export", tint: tokens.semantic.import, isEnabled: Boolean(page()), action: () => {
        const current = page()
        if (current) {
            exportNote(current, library.noteTitle(current), { showsGuides: preferences.showsGuides(), showsDividers: preferences.showsDividers(), paperStyle: preferences.paperStyle() })
        }
    } })
    const leftColumn = create("div", "settings-column", asciiModule, create("div", "settings-links", importButton, exportButton), importFailure)

    const paperToggle = segmented([{ value: "dark", title: "Dark" }, { value: "light", title: "White" }], preferences.paperStyle(), (style) => preferences.setPaperStyle(style))
    const rule = create("span", "settings-rule")
    const rowButton = linkButton({ glyphName: "add_row", title: "Row", tint: tokens.semantic.create, isEnabled: isPageEditable(), action: () => pageContext && library.expand(pageContext.pageId, false) })
    const columnButton = linkButton({ glyphName: "add_column", title: "Column", tint: tokens.semantic.create, isEnabled: isPageEditable(), action: () => pageContext && library.expand(pageContext.pageId, true) })
    const gridButton = linkButton({ glyphName: "guides", title: "Grid", tint: tokens.semantic.view, isOn: preferences.showsGuides(), action: () => {
        preferences.setShowsGuides(!preferences.showsGuides())
        gridButton.update({ isOn: preferences.showsGuides() })
    } })
    const dividerButton = linkButton({ glyphName: "cell_lines", title: "Divider", tint: tokens.semantic.view, isOn: preferences.showsDividers(), action: () => {
        preferences.setShowsDividers(!preferences.showsDividers())
        dividerButton.update({ isOn: preferences.showsDividers() })
    } })
    const paperModule = settingsModule("Paper", null, paperToggle, rule, create("div", "settings-grid", rowButton, columnButton, gridButton, dividerButton))
    const smoothingRange = tokens.ink.smoothing_range
    const penModule = settingsModule("Pen", null, settingsSlider("Smoothing", rangeShare(preferences.inkSmoothing(), smoothingRange), preferences.inkSmoothing().toFixed(1), (share) => {
        preferences.setInkSmoothing(rangeValue(share, smoothingRange))
        return preferences.inkSmoothing().toFixed(1)
    }))
    const rightColumn = create("div", "settings-column", paperModule, penModule)

    const settings = syncSettings()
    const owner = field({ placeholder: "Owner", value: settings.owner })
    const repository = field({ placeholder: "Repository", value: settings.repository })
    const branch = field({ placeholder: "Branch", value: settings.branch })
    const token = field({ placeholder: app.sync.hasToken ? "Token stored in Credential Manager" : "Fine-grained token", isSecret: true })
    const failure = create("span", "sync-failure")
    const blocked = create("div", "sync-blocked")
    const save = slabButton("Save", tokens.semantic.create, () => {
        app.sync.configure({ owner: owner.input.value.trim(), repository: repository.input.value.trim(), branch: branch.input.value.trim() }, token.input.value || null)
        app.navigator.show(null)
    })
    const refreshSave = () => setEnabled(save, Boolean(owner.input.value && repository.input.value && branch.input.value))
    for (const input of [owner.input, repository.input, branch.input, token.input]) {
        input.addEventListener("input", refreshSave)
        input.addEventListener("keydown", (event) => event.stopPropagation())
    }
    refreshSave()
    const syncModule = settingsModule("GitHub sync", "", create("div", "sync-fields", owner, create("span", "sync-divider", "/"), repository, create("span", "sync-divider", "|"), branch), token, failure, blocked, save)
    const renderSync = () => {
        syncModule.header.detail.textContent = `${app.sync.statusLabel()} · ${app.sync.queuedCount} queued`.toUpperCase()
        failure.textContent = app.sync.status.kind === "failed" ? app.sync.status.message : ""
        failure.hidden = app.sync.status.kind !== "failed"
        blocked.replaceChildren(...[...library.blockedPaths.entries()].sort().map(([path, reason]) => microLabel(`${reason} · ${path}`, tokens.semantic.destructive)))
    }
    renderSync()

    let isDeleteArmed = false
    let armTimer = null
    const deleteButton = linkButton({ glyphName: "trash", title: "Delete note", tint: tokens.semantic.destructive, isEnabled: Boolean(page()), action: () => {
        if (!pageContext) {
            return
        }
        if (!isDeleteArmed) {
            isDeleteArmed = true
            deleteButton.update({ title: "Tap again to delete", isOn: true })
            clearTimeout(armTimer)
            armTimer = setTimeout(() => {
                isDeleteArmed = false
                deleteButton.update({ title: "Delete note", isOn: false })
            }, armedMilliseconds)
            return
        }
        library.deletePage(pageContext.pageId)
        app.navigator.show(null)
        app.navigator.go({ kind: "notebook", notebookId: pageContext.notebookId })
    } })
    deleteButton.classList.add("settings-delete")

    const panels = create("div", "settings-panels", create("div", "settings-columns", leftColumn, rightColumn), syncModule, deleteButton)
    const sheet = create("div", "settings-sheet", panels)
    sheet.refresh = () => {
        renderSync()
        renderAscii(false)
        asciiToggle.select(preferences.showsAsciiBackground(), true)
        paperToggle.select(preferences.paperStyle(), true)
    }
    sheet.unsubscribe = app.sync.subscribe(() => renderSync())
    return sheet
}

function buildContent(app, request) {
    const library = app.library
    switch (request.kind) {
    case "newFolder":
        return nameSheet({ heading: "New folder", initial: `Folder ${library.folders(request.parentId).length + 1}`, confirmTitle: "Create", confirmColor: tokens.semantic.create, selectsAll: true, confirm: (title) => {
            const notebook = library.createNotebook(title, request.parentId)
            app.navigator.show(null)
            app.navigator.go({ kind: "notebook", notebookId: notebook.id })
        } })
    case "renameFolder":
        return nameSheet({ heading: "Rename folder", initial: library.notebook(request.notebookId)?.title ?? "", confirmTitle: "Rename", confirmColor: tokens.semantic.edit, confirm: (title) => {
            library.updateNotebook(request.notebookId, { title })
            app.navigator.show(null)
        } })
    case "renameNote": {
        const page = library.page(request.pageId)
        return nameSheet({ heading: "Rename note", initial: page ? library.noteTitle(page) : "", confirmTitle: "Rename", confirmColor: tokens.semantic.edit, confirm: (title) => {
            library.updatePage(request.pageId, { title })
            app.navigator.show(null)
        } })
    }
    case "renameGroup":
        return nameSheet({ heading: "Rename group", initial: preferences.groups(request.parentId).find((group) => group.id === request.groupId)?.title ?? "", confirmTitle: "Rename", confirmColor: tokens.semantic.edit, confirm: (title) => {
            preferences.renameGroup(request.groupId, title, request.parentId)
            app.navigator.show(null)
        } })
    case "pickGroup":
        return groupSheet(app, request)
    case "appearance":
        return appearanceSheet(app, request)
    case "move":
        return moveSheet(app, request)
    case "newNote":
        return newNoteSheet(app, request)
    case "settings":
        return settingsSheet(app)
    default:
        return null
    }
}

export class SheetHost {
    constructor(app, request) {
        this.app = app
        this.request = request
        this.isNaming = isNaming(request)
        this.isRaised = false
        this.element = create("div", `sheet-host ${this.isNaming ? "is-naming" : request.kind === "settings" ? "is-settings" : "is-overlay"}`)
        this.backdrop = create("div", "sheet-backdrop")
        this.backdrop.addEventListener("pointerdown", () => app.navigator.show(null))
        this.content = buildContent(app, request)
        this.frame = create("div", "sheet-frame", this.content)
        this.frame.addEventListener("pointerdown", (event) => {
            if (event.target === this.frame) {
                app.navigator.show(null)
            }
        })
        this.element.append(this.backdrop, this.frame)
        this.element.addEventListener("keydown", (event) => {
            if (event.key === "Escape") {
                app.navigator.show(null)
            }
        })
        app.overlayHost.append(this.element)
        this.enter()
    }

    keyboardLift() {
        return Math.max(this.app.keyboardHeight, 0) + 24
    }

    enter() {
        if (this.isNaming) {
            this.frame.style.paddingBottom = `${this.keyboardLift()}px`
            this.frame.style.transform = `translateY(${this.frame.offsetHeight}px)`
            this.content.focusTarget?.focus({ preventScroll: true })
            this.raiseTimer = setTimeout(() => this.raise(), duration("keyboard") * 2)
            return
        }
        this.backdrop.style.opacity = "1"
        animate(this.backdrop, [{ opacity: 0 }, { opacity: 1 }], { milliseconds: duration("overlay_enter"), curveName: "power_two_out" })
        if (this.request.kind === "settings") {
            animate(this.content, [{ transform: `translateY(${-this.frame.offsetHeight}px)` }, { transform: "translateY(0)" }], { milliseconds: duration("sheet_drop"), curveName: "power_two_out" })
        } else {
            animate(this.content, [{ opacity: 0, transform: "translateY(24px) scale(0.94)" }, { opacity: 1, transform: "translateY(0) scale(1)" }], { milliseconds: duration("overlay_enter"), curveName: "power_two_out" })
        }
    }

    raise(milliseconds = duration("keyboard")) {
        clearTimeout(this.raiseTimer)
        if (this.isLeaving) {
            return
        }
        this.isRaised = true
        this.frame.style.transition = `transform ${milliseconds}ms ${curve("keyboard")}, padding-bottom ${milliseconds}ms ${curve("keyboard")}`
        this.backdrop.style.transition = `opacity ${milliseconds}ms ${curve("keyboard")}`
        this.frame.style.paddingBottom = `${this.keyboardLift()}px`
        this.frame.style.transform = "translateY(0)"
        this.backdrop.style.opacity = "1"
    }

    keyboardChanged() {
        if (this.isNaming && !this.isLeaving) {
            this.raise()
        }
    }

    refresh() {
        this.content.refresh?.()
    }

    leave() {
        this.isLeaving = true
        clearTimeout(this.raiseTimer)
        this.content.unsubscribe?.()
        this.element.style.pointerEvents = "none"
        let milliseconds = duration("overlay_leave")
        if (this.isNaming) {
            milliseconds = duration("keyboard")
            document.activeElement?.blur?.()
            this.frame.style.transition = `transform ${milliseconds}ms ${curve("keyboard")}`
            this.backdrop.style.transition = `opacity ${milliseconds}ms ${curve("keyboard")}`
            this.frame.style.transform = `translateY(${this.frame.offsetHeight}px)`
            this.backdrop.style.opacity = "0"
        } else if (this.request.kind === "settings") {
            milliseconds = duration("sheet_drop")
            animate(this.content, [{ transform: "translateY(0)" }, { transform: `translateY(${-this.frame.offsetHeight}px)` }], { milliseconds, curveName: "power_two_in", fill: "forwards" })
            animate(this.backdrop, [{ opacity: 1 }, { opacity: 0 }], { milliseconds, curveName: "power_two_in", fill: "forwards" })
        } else {
            animate(this.content, [{ opacity: 1, transform: "scale(1)" }, { opacity: 0, transform: "scale(0.96)" }], { milliseconds, curveName: "power_two_in", fill: "forwards" })
            animate(this.backdrop, [{ opacity: 1 }, { opacity: 0 }], { milliseconds, curveName: "power_two_in", fill: "forwards" })
        }
        return new Promise((resolve) => setTimeout(() => {
            this.element.remove()
            resolve()
        }, milliseconds))
    }
}

