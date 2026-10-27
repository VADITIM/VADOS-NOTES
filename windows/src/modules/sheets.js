import { create, field, microLabel, slabButton } from "./components.js"
import { paperStyle, setPaperStyle } from "./preferences.js"
import { glyph, squircle, squircleRadius } from "./shapes.js"
import { readSetting, writeSetting } from "./storage.js"
import { tokens } from "./tokens.js"

function sheetPanel(heading, ...content) {
    const panel = create("div", "sheet-panel", microLabel(heading), ...content)
    squircle(panel, { radius: squircleRadius.sheet, fill: tokens.palette.panel_solid, border: tokens.palette.border_strong })
    return panel
}

function nameSheet(app, { heading, initial, confirmTitle, confirmColor, confirm }) {
    const title = field({ placeholder: "Name", value: initial })
    const submit = () => {
        const trimmed = title.input.value.trim()
        if (trimmed) {
            confirm(trimmed)
        }
    }
    const button = slabButton(confirmTitle, confirmColor, submit)
    const refresh = () => button.setEnabled(title.input.value.trim().length > 0)
    title.input.addEventListener("input", refresh)
    title.input.addEventListener("keydown", (event) => {
        if (event.key === "Enter") {
            submit()
        }
    })
    refresh()
    const panel = sheetPanel(heading, title, button)
    panel.focusTarget = title.input
    panel.selectsAll = true
    return panel
}

export function folderLook(notebook) {
    return { color: notebook?.color ?? tokens.folders.default_color, icon: notebook?.icon ?? tokens.folders.default_icon }
}

export function noteLook(page) {
    return { color: page?.color ?? tokens.palette.text_muted, icon: page?.icon ?? tokens.folders.note_icon }
}

function targetDetails(app, target) {
    const library = app.library
    if (target.kind === "folder") {
        const notebook = library.notebook(target.id)
        return notebook ? { title: notebook.title, look: folderLook(notebook), apply: (changes) => library.updateNotebook(target.id, changes) } : null
    }
    const page = library.page(target.id)
    return page ? { title: page.title ?? "Note", look: noteLook(page), apply: (changes) => library.updatePage(target.id, changes) } : null
}

function choiceButton(className, content, label, onPick) {
    const button = create("button", `${className} pressable`, content)
    button.type = "button"
    button.setAttribute("aria-label", label)
    button.title = label
    button.addEventListener("click", onPick)
    return button
}

function appearanceSheet(app, target) {
    const details = targetDetails(app, target)
    if (!details) {
        return null
    }
    let look = { ...details.look }
    const previewIcon = create("span", "appearance-preview-icon")
    const preview = create("div", "appearance-preview", previewIcon, create("span", "appearance-preview-title", details.title))
    const colorButtons = tokens.folders.colors.map((color) => {
        const dot = create("span", "swatch-dot")
        dot.style.background = color
        const button = choiceButton("swatch-button appearance-color", dot, color, () => pick({ color }))
        button.value = color
        return button
    })
    const iconButtons = tokens.folders.icons.map((icon) => {
        const button = choiceButton("appearance-icon", glyph(icon, { size: 24 }), icon, () => pick({ icon }))
        button.value = icon
        return button
    })
    const paint = () => {
        previewIcon.replaceChildren(glyph(look.icon, { size: 30, color: look.color }))
        for (const button of colorButtons) {
            button.classList.toggle("is-selected", button.value === look.color)
        }
        for (const button of iconButtons) {
            const isSelected = button.value === look.icon
            button.classList.toggle("is-selected", isSelected)
            button.style.color = isSelected ? look.color : ""
        }
    }
    const pick = (changes) => {
        look = { ...look, ...changes }
        details.apply(changes)
        paint()
    }
    paint()
    return sheetPanel(
        target.kind === "folder" ? "Folder icon and colour" : "Note icon and colour",
        preview,
        create("div", "appearance-colors", ...colorButtons),
        create("div", "appearance-icons", ...iconButtons),
        slabButton("Done", tokens.semantic.create, () => app.showSheet(null)),
    )
}

function folderTree(library, parentId = null, depth = 0) {
    return library.folders(parentId).flatMap((notebook) => [{ notebook, depth }, ...folderTree(library, notebook.id, depth + 1)])
}

function moveRow({ icon, color, title, depth, isCurrent, isEnabled, onPick }) {
    const row = create(
        "button",
        "move-row pressable-soft",
        create("span", "move-row-icon", glyph(icon, { size: 20, color })),
        create("span", "move-row-title", title),
        isCurrent ? microLabel("Here") : null,
    )
    row.type = "button"
    row.style.paddingLeft = `${16 + depth * 22}px`
    row.disabled = !isEnabled
    row.classList.toggle("is-disabled", !isEnabled)
    row.addEventListener("click", () => {
        if (isEnabled) {
            onPick()
        }
    })
    return row
}

function moveSheet(app, target) {
    const library = app.library
    const details = targetDetails(app, target)
    if (!details) {
        return null
    }
    const rows = []
    const finish = () => app.showSheet(null)
    if (target.kind === "folder") {
        const currentParent = library.parentOf(target.id)
        rows.push(moveRow({
            icon: "home",
            color: tokens.palette.text_bright,
            title: "Folders",
            depth: 0,
            isCurrent: currentParent === null,
            isEnabled: currentParent !== null,
            onPick: () => {
                library.moveNotebook(target.id, null)
                finish()
            },
        }))
    }
    const currentFolder = target.kind === "folder" ? library.parentOf(target.id) : library.page(target.id)?.notebook
    for (const { notebook, depth } of folderTree(library)) {
        const look = folderLook(notebook)
        const isCurrent = notebook.id === currentFolder
        const isEnabled = !isCurrent && (target.kind === "note" || library.canMoveNotebook(target.id, notebook.id))
        rows.push(moveRow({
            icon: look.icon,
            color: look.color,
            title: notebook.title,
            depth: depth + (target.kind === "folder" ? 1 : 0),
            isCurrent,
            isEnabled,
            onPick: () => {
                if (target.kind === "folder") {
                    library.moveNotebook(target.id, notebook.id)
                } else {
                    library.movePage(target.id, notebook.id)
                }
                finish()
            },
        }))
    }
    return sheetPanel(`Move “${details.title}”`, create("div", "move-list", ...rows))
}

function segmented(options, selected, onPick) {
    const wash = create("span", "segmented-wash")
    const buttons = options.map(({ value, title }) => {
        const button = create("button", "segmented-option pressable", title)
        button.type = "button"
        button.value = value
        button.addEventListener("click", () => {
            paint(value)
            onPick(value)
        })
        return button
    })
    const element = create("div", "segmented", wash, ...buttons)
    const paint = (value) => {
        const index = options.findIndex((option) => option.value === value)
        wash.style.transform = `translateX(${index * 100}%)`
        wash.style.width = `calc((100% - 8px) / ${options.length})`
        for (const button of buttons) {
            button.classList.toggle("is-selected", button.value === value)
        }
    }
    paint(selected)
    return element
}

function settingsSheet(app) {
    const settings = readSetting("syncSettings", { owner: "", repository: "", branch: "main" })
    const owner = field({ placeholder: "Owner", value: settings.owner })
    const repository = field({ placeholder: "Repository", value: settings.repository })
    const branch = field({ placeholder: "Branch", value: settings.branch })
    const token = field({ placeholder: "Fine-grained token", isSecret: true })
    const status = app.syncStatus()
    const button = slabButton("Save", tokens.semantic.create, () => {
        writeSetting("syncSettings", { owner: owner.input.value.trim(), repository: repository.input.value.trim(), branch: branch.input.value.trim() })
        app.showSheet(null)
    })
    const refresh = () => button.setEnabled([owner, repository, branch].every((item) => item.input.value.trim().length > 0))
    for (const item of [owner, repository, branch]) {
        item.input.addEventListener("input", refresh)
    }
    refresh()
    const panel = sheetPanel(
        "Settings",
        create("div", "settings-section",
            microLabel("Paper", tokens.palette.text_muted),
            segmented([{ value: "dark", title: "Dark" }, { value: "light", title: "White" }], paperStyle(), setPaperStyle),
        ),
        create("div", "settings-section",
            create("div", "sheet-status", microLabel("GitHub sync", tokens.palette.text_muted), microLabel(status.label, status.color)),
            create("div", "field-row", owner, create("span", "field-divider", "/"), repository),
            branch,
            token,
            create("p", "sheet-note", "Sync on Windows is not built yet (roadmap phase 6). Settings are kept for when it lands; the token is not stored."),
        ),
        button,
    )
    return panel
}

export function buildSheet(app, request) {
    const library = app.library
    switch (request.kind) {
    case "new-folder":
        return nameSheet(app, {
            heading: "New folder",
            initial: "",
            confirmTitle: "Create",
            confirmColor: tokens.semantic.create,
            confirm: (title) => {
                const notebook = library.createNotebook(title, request.parentId ?? null)
                app.showSheet(null)
                app.go({ kind: "notebook", notebookId: notebook.id })
            },
        })
    case "rename-folder":
        return nameSheet(app, {
            heading: "Rename folder",
            initial: library.notebook(request.notebookId)?.title ?? "",
            confirmTitle: "Rename",
            confirmColor: tokens.semantic.edit,
            confirm: (title) => {
                library.rename(request.notebookId, title)
                app.showSheet(null)
            },
        })
    case "rename-note":
        return nameSheet(app, {
            heading: "Rename note",
            initial: library.page(request.pageId)?.title ?? "",
            confirmTitle: "Rename",
            confirmColor: tokens.semantic.edit,
            confirm: (title) => {
                library.updatePage(request.pageId, { title })
                app.showSheet(null)
            },
        })
    case "appearance":
        return appearanceSheet(app, request.target)
    case "move":
        return moveSheet(app, request.target)
    case "settings":
        return settingsSheet(app)
    default:
        return null
    }
}
