import { decodeFile, repositoryPathKind, schemaVersion } from "./model.js"
import { loadSyncedFiles, readSetting, readSyncState, readToken, saveToken, writeSetting, writeSyncedFile, writeSyncState } from "./storage.js"
import { tokens } from "./tokens.js"

const apiUrl = "https://api.github.com"
const readmeContent = "# VAD/OS Notes\n\nSynced by VAD/OS Notes. Do not edit page files by hand.\n"
const settingsKey = "syncSettings"
const pullIntervalMilliseconds = 60000
const retryIntervalMilliseconds = 30000

class RemoteError extends Error {
    constructor(kind, status = 0, message = kind) {
        super(message)
        this.kind = kind
        this.status = status
    }
}

function encodeBase64(text) {
    const bytes = new TextEncoder().encode(text)
    let binary = ""
    for (let index = 0; index < bytes.length; index += 0x8000) {
        binary += String.fromCharCode(...bytes.subarray(index, index + 0x8000))
    }
    return btoa(binary)
}

function decodeBase64(text) {
    const binary = atob(text.replace(/\s/g, ""))
    const bytes = Uint8Array.from(binary, (character) => character.charCodeAt(0))
    return new TextDecoder().decode(bytes)
}

class GitHubRemote {
    constructor(owner, repository, token) {
        this.base = `${apiUrl}/repos/${encodeURIComponent(owner)}/${encodeURIComponent(repository)}`
        this.token = token
    }

    async request(method, path, body) {
        let response
        try {
            response = await fetch(path ? `${this.base}/${path}` : this.base, {
                method,
                cache: "no-store",
                headers: {
                    Authorization: `Bearer ${this.token}`,
                    Accept: "application/vnd.github+json",
                    "X-GitHub-Api-Version": "2022-11-28",
                    ...(body ? { "Content-Type": "application/json" } : {}),
                },
                body: body ? JSON.stringify(body) : undefined,
            })
        } catch (error) {
            throw new RemoteError("transport", 0, String(error))
        }
        if (response.status === 401 || response.status === 403) {
            throw new RemoteError("unauthorized", response.status)
        }
        if (response.status === 404) {
            throw new RemoteError("notFound", 404)
        }
        if (!response.ok) {
            throw new RemoteError("server", response.status, await response.text())
        }
        return response.json()
    }

    async headCommit(branch) {
        try {
            return (await this.request("GET", `git/ref/heads/${branch}`)).object.sha
        } catch (error) {
            if (error.kind === "notFound" || (error.kind === "server" && error.status === 409)) {
                return null
            }
            throw error
        }
    }

    async initialize(branch) {
        const repository = await this.request("GET", "")
        const defaultBranch = repository.default_branch
        const defaultHead = await this.headCommit(defaultBranch)
        if (defaultHead) {
            return (await this.request("POST", "git/refs", { ref: `refs/heads/${branch}`, sha: defaultHead })).object.sha
        }
        const created = await this.request("PUT", "contents/README.md", { message: "Start VAD/OS Notes", content: encodeBase64(readmeContent), branch: defaultBranch })
        if (branch === defaultBranch) {
            return created.commit.sha
        }
        return (await this.request("POST", "git/refs", { ref: `refs/heads/${branch}`, sha: created.commit.sha })).object.sha
    }

    async files(commit) {
        const commitResponse = await this.request("GET", `git/commits/${commit}`)
        const tree = await this.request("GET", `git/trees/${commitResponse.tree.sha}?recursive=1`)
        if (tree.truncated) {
            throw new RemoteError("server", 0, "Repository tree is too large to list in one request")
        }
        const files = new Map()
        for (const entry of tree.tree) {
            if (entry.type === "blob") {
                files.set(entry.path, entry.sha)
            }
        }
        return files
    }

    async blob(sha) {
        const blob = await this.request("GET", `git/blobs/${sha}`)
        if (blob.encoding !== "base64") {
            throw new RemoteError("server", 0, `Blob ${sha} is not base64`)
        }
        return decodeBase64(blob.content)
    }

    async commit(files, parent, message) {
        const blobs = new Map()
        for (const [path, contents] of [...files.entries()].sort(([first], [second]) => (first < second ? -1 : 1))) {
            const created = await this.request("POST", "git/blobs", { content: encodeBase64(contents), encoding: "base64" })
            blobs.set(path, created.sha)
        }
        const parentCommit = await this.request("GET", `git/commits/${parent}`)
        const entries = [...blobs.entries()].sort(([first], [second]) => (first < second ? -1 : 1)).map(([path, sha]) => ({ path, mode: "100644", type: "blob", sha }))
        const tree = await this.request("POST", "git/trees", { base_tree: parentCommit.tree.sha, tree: entries })
        const commit = await this.request("POST", "git/commits", { message, tree: tree.sha, parents: [parent] })
        return { sha: commit.sha, blobs }
    }

    async moveBranch(branch, commit) {
        try {
            await this.request("PATCH", `git/refs/heads/${branch}`, { sha: commit, force: false })
        } catch (error) {
            if (error.kind === "server" && (error.status === 409 || error.status === 422)) {
                throw new RemoteError("rejected", error.status)
            }
            throw error
        }
    }
}

function classify(contents, path) {
    const kind = repositoryPathKind(path)
    if (!kind) {
        return { isValid: true }
    }
    try {
        const value = JSON.parse(contents)
        if (value.schema_version !== schemaVersion) {
            return { isValid: false, reason: "unsupported_version" }
        }
        const prefix = kind.kind === "page" ? "p_" : "nb_"
        if (typeof value.id !== "string" || !value.id.startsWith(prefix)) {
            return { isValid: false, reason: "corrupt_remote" }
        }
        if (kind.kind === "page" && (!(value.extent?.cols >= 1) || !(value.extent?.rows >= 1) || !Array.isArray(value.elements))) {
            return { isValid: false, reason: "corrupt_remote" }
        }
        return { isValid: true, value: decodeFile(contents).value }
    } catch {
        return { isValid: false, reason: "corrupt_remote" }
    }
}

export function syncSettings() {
    const stored = readSetting(settingsKey, null)
    return { owner: stored?.owner ?? "", repository: stored?.repository ?? "", branch: stored?.branch ?? "main" }
}

function isComplete(settings) {
    return Boolean(settings.owner && settings.repository && settings.branch)
}

export class SyncCoordinator {
    constructor(library) {
        this.library = library
        this.settings = syncSettings()
        this.state = { head: null, blobs: {}, blocked: {}, lastSynced: null }
        this.snapshot = new Map()
        this.status = { kind: "notConnected" }
        this.hasToken = false
        this.listeners = new Set()
        this.firstChange = null
        this.lastInput = null
        this.flushTimer = null
        this.pullTimer = null
        this.isRunning = false
        this.isRunRequested = false
        library.onChange = () => this.recordChange()
        library.onInput = () => this.recordInput()
    }

    async open() {
        this.state = { ...this.state, ...((await readSyncState()) ?? {}) }
        for (const file of await loadSyncedFiles()) {
            this.snapshot.set(file.path, file.contents)
        }
        this.hasToken = Boolean(await readToken())
        if (this.library.dirtyPaths.size) {
            this.recordChange()
        }
        this.refreshIdleStatus()
        this.startPulling()
        document.addEventListener("visibilitychange", () => {
            if (document.visibilityState === "visible") {
                this.startPulling()
                this.flush()
            } else {
                this.flush()
            }
        })
        this.flush()
    }

    subscribe(listener) {
        this.listeners.add(listener)
        return () => this.listeners.delete(listener)
    }

    announce() {
        for (const listener of this.listeners) {
            listener()
        }
    }

    get isConfigured() {
        return isComplete(this.settings) && this.hasToken
    }

    get queuedCount() {
        return this.library.dirtyPaths.size
    }

    statusLabel() {
        switch (this.status.kind) {
        case "syncing": return "Syncing"
        case "synced": {
            const date = new Date(this.status.date)
            return `Synced ${String(date.getHours()).padStart(2, "0")}:${String(date.getMinutes()).padStart(2, "0")}`
        }
        case "paused": return "Sync paused"
        case "offline": return `Offline · ${this.status.queued} queued`
        case "retrying": return `Retrying · ${this.status.queued} queued`
        case "failed": return "Sync failed"
        default: return "Not connected"
        }
    }

    async configure(settings, token) {
        this.settings = settings
        writeSetting(settingsKey, settings)
        if (token) {
            await saveToken(token)
            this.hasToken = true
        }
        this.refreshIdleStatus()
        this.flush()
    }

    recordInput() {
        if (!this.firstChange) {
            return
        }
        this.lastInput = Date.now()
        this.scheduleFlush()
    }

    recordChange() {
        const now = Date.now()
        this.firstChange = this.firstChange ?? now
        this.lastInput = Math.max(this.lastInput ?? now, now)
        this.scheduleFlush()
    }

    nextDeadline() {
        if (!this.firstChange) {
            return null
        }
        const idle = (this.lastInput ?? this.firstChange) + tokens.sync.idle_seconds * 1000
        return Math.min(idle, this.firstChange + tokens.sync.max_age_seconds * 1000)
    }

    scheduleFlush() {
        clearTimeout(this.flushTimer)
        const deadline = this.nextDeadline()
        if (deadline === null) {
            return
        }
        this.flushTimer = setTimeout(() => this.flush(), Math.max(50, deadline - Date.now()))
    }

    scheduleRetry() {
        clearTimeout(this.flushTimer)
        this.flushTimer = setTimeout(() => this.flush(), retryIntervalMilliseconds)
    }

    startPulling() {
        clearInterval(this.pullTimer)
        this.pullTimer = setInterval(() => this.flush(), pullIntervalMilliseconds)
    }

    refreshIdleStatus() {
        if (!this.isConfigured) {
            this.status = { kind: "notConnected" }
        } else if (this.state.lastSynced) {
            this.status = { kind: "synced", date: this.state.lastSynced }
        }
        this.announce()
    }

    flush() {
        this.run()
    }

    async run() {
        const token = isComplete(this.settings) ? await readToken() : null
        if (!token) {
            this.status = { kind: "notConnected" }
            this.announce()
            return
        }
        if (this.isRunning) {
            this.isRunRequested = true
            return
        }
        this.isRunning = true
        this.status = { kind: "syncing" }
        this.announce()
        this.firstChange = null
        this.lastInput = null
        let didSucceed = false
        try {
            await this.library.flush()
            await this.synchronize(new GitHubRemote(this.settings.owner, this.settings.repository, token))
            this.status = { kind: "synced", date: this.state.lastSynced ?? new Date().toISOString() }
            didSucceed = true
        } catch (error) {
            const queued = this.queuedCount
            if (error.kind === "unauthorized") {
                this.status = { kind: "paused" }
            } else if (error.kind === "transport") {
                this.status = { kind: "offline", queued }
                this.scheduleRetry()
            } else if (error.kind === "gaveUp") {
                this.status = { kind: "retrying", queued }
                this.scheduleRetry()
            } else {
                this.status = { kind: "failed", message: error.message || String(error) }
                this.scheduleRetry()
            }
        }
        const hasPushable = [...this.library.dirtyPaths.keys()].some((path) => !this.library.blockedPaths.has(path))
        if (hasPushable) {
            this.firstChange = this.firstChange ?? Date.now()
            this.lastInput = this.lastInput ?? Date.now()
            if (didSucceed) {
                this.scheduleFlush()
            }
        }
        this.isRunning = false
        this.library.changed()
        this.announce()
        if (this.isRunRequested) {
            this.isRunRequested = false
            await this.run()
        }
    }

    async synchronize(remote) {
        const backoff = tokens.sync.backoff_seconds
        for (let attempt = 1; ; attempt += 1) {
            try {
                const head = await this.pull(remote)
                await this.push(remote, head)
                this.state.lastSynced = new Date().toISOString()
                await writeSyncState(this.state)
                return
            } catch (error) {
                if (error.kind !== "rejected") {
                    throw error
                }
                if (attempt > backoff.length) {
                    throw new RemoteError("gaveUp")
                }
                await new Promise((resolve) => setTimeout(resolve, backoff[attempt - 1] * 1000))
            }
        }
    }

    async pull(remote) {
        let head = await remote.headCommit(this.settings.branch)
        if (!head) {
            head = await remote.initialize(this.settings.branch)
        }
        if (head === this.state.head) {
            return head
        }
        const remoteFiles = await remote.files(head)
        const blobs = { ...this.state.blobs }
        const blocked = { ...this.state.blocked }
        for (const [path, sha] of [...remoteFiles.entries()].sort(([first], [second]) => (first < second ? -1 : 1))) {
            if (!repositoryPathKind(path) || blobs[path] === sha) {
                continue
            }
            const contents = await remote.blob(sha)
            blobs[path] = sha
            const classification = classify(contents, path)
            if (classification.isValid) {
                this.snapshot.set(path, contents)
                await writeSyncedFile(path, contents)
                delete blocked[path]
                this.library.absorbRemote(path, classification.value)
            } else {
                blocked[path] = classification.reason
            }
        }
        this.state = { ...this.state, head, blobs, blocked }
        this.library.blockedPaths = new Map(Object.entries(blocked))
        this.library.refreshReadOnly()
        await writeSyncState(this.state)
        await this.library.flush()
        return head
    }

    async push(remote, head) {
        const captured = new Map(this.library.dirtyPaths)
        if (!captured.size) {
            return
        }
        const files = new Map()
        const settled = new Map()
        for (const [path, counter] of captured) {
            if (this.library.blockedPaths.has(path)) {
                continue
            }
            const contents = this.library.encodedFile(path)
            if (contents === null || contents === this.snapshot.get(path)) {
                settled.set(path, counter)
            } else {
                files.set(path, contents)
            }
        }
        if (!files.size) {
            this.library.settle(settled)
            return
        }
        const pageCount = [...files.keys()].filter((path) => path.includes("/pages/")).length
        const message = `Sync ${pageCount} page${pageCount === 1 ? "" : "s"} from ${this.library.device}`
        const result = await remote.commit(files, head, message)
        await remote.moveBranch(this.settings.branch, result.sha)
        for (const [path, contents] of files) {
            this.snapshot.set(path, contents)
            await writeSyncedFile(path, contents)
            settled.set(path, captured.get(path))
        }
        this.state.head = result.sha
        for (const [path, sha] of result.blobs) {
            this.state.blobs[path] = sha
        }
        this.library.settle(settled)
    }
}
