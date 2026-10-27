import { create, field, microLabel, slabButton } from "./components.js"
import { squircle, squircleRadius } from "./shapes.js"
import { readSetting, writeSetting } from "./storage.js"
import { tokens } from "./tokens.js"

function sheetPanel(heading, ...content) {
    const panel = create("div", "sheet-panel", microLabel(heading), ...content)
    squircle(panel, { radius: squircleRadius.sheet, fill: tokens.palette.panel_solid, border: tokens.palette.border_strong })
    return panel
}

function nameSheet(app, { heading, initial, confirmTitle, confirmColor, confirm }) {
    const title = field({ placeholder: "Title", value: initial })
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
    return panel
}

function syncSheet(app) {
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
        "Sync with GitHub",
        create("div", "field-row", owner, create("span", "field-divider", "/"), repository),
        branch,
        token,
        create("div", "sheet-status", microLabel(status.label, tokens.palette.text_muted), microLabel("0 queued")),
        create("p", "sheet-note", "Sync on Windows is not built yet (roadmap phase 6). Settings are kept for when it lands; the token is not stored."),
        button,
    )
    panel.focusTarget = owner.input
    return panel
}

export function buildSheet(app, request) {
    switch (request.kind) {
    case "new-notebook":
        return nameSheet(app, {
            heading: "New notebook",
            initial: "",
            confirmTitle: "Create",
            confirmColor: tokens.semantic.create,
            confirm: (title) => {
                const notebook = app.library.createNotebook(title)
                app.showSheet(null)
                app.go({ kind: "notebook", notebookId: notebook.id })
            },
        })
    case "rename":
        return nameSheet(app, {
            heading: "Rename",
            initial: request.title,
            confirmTitle: "Rename",
            confirmColor: tokens.semantic.edit,
            confirm: (title) => {
                app.library.rename(request.notebookId, title)
                app.showSheet(null)
            },
        })
    case "sync":
        return syncSheet(app)
    default:
        return null
    }
}
