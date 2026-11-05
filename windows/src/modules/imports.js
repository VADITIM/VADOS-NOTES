import { cellHeight, cellWidth } from "./model.js"
import { paperStyle } from "./preferences.js"
import { readAsset, writeAsset } from "./storage.js"
import { tokens } from "./tokens.js"

const millimetresPerPoint = 25.4 / 72
const maximumImagePixels = 4096
const minimumLevel = 0.5
const edgeSampleCount = 48
const whiteLuminance = 0.88
const whiteShare = 0.8

const documents = new Map()
const pageSizes = new Map()
const images = new Map()
const listeners = new Set()
let queue = Promise.resolve()
const holders = new Set()

export function importHolder() {
    const keys = new Set()
    holders.add(keys)
    return keys
}

export function releaseImportHolder(keys) {
    holders.delete(keys)
}

function heldKeys() {
    const held = new Set()
    for (const keys of holders) {
        for (const key of keys) {
            held.add(key)
        }
    }
    return held
}
let pdfLibrary = null

function vendorUrl(path) {
    return new URL(`../vendor/pdfjs/${path}`, import.meta.url).href
}

function library() {
    if (!pdfLibrary) {
        pdfLibrary = import("../vendor/pdfjs/pdf.min.mjs").then((module) => {
            module.GlobalWorkerOptions.workerSrc = vendorUrl("pdf.worker.min.mjs")
            return module
        })
    }
    return pdfLibrary
}

async function openDocument(bytes) {
    const pdfjs = await library()
    return pdfjs.getDocument({
        data: bytes,
        standardFontDataUrl: vendorUrl("standard_fonts/"),
        cMapUrl: vendorUrl("cmaps/"),
        cMapPacked: true,
        isEvalSupported: false,
    }).promise
}

class ImportError extends Error {
    constructor(kind) {
        super(kind)
        this.kind = kind
    }
}

function hexOf(buffer) {
    return [...new Uint8Array(buffer)].map((value) => value.toString(16).padStart(2, "0")).join("")
}

export async function assetIdentifier(bytes) {
    return `sha256:${hexOf(await crypto.subtle.digest("SHA-256", bytes))}`
}

export function assetByteLimit() {
    return tokens.sync.asset_limit_megabytes * 1024 * 1024
}

export function importFailureMessage(error) {
    return error?.kind === "tooLarge" ? `LARGER THAN ${tokens.sync.asset_limit_megabytes} MB` : "NOT A READABLE PDF"
}

export function assetPath(asset) {
    return `assets/${asset.replace("sha256:", "")}.pdf`
}

export function subscribeImports(listener) {
    listeners.add(listener)
    return () => listeners.delete(listener)
}

let revision = 0

export function importsRevision() {
    return revision
}

function announce() {
    revision += 1
    for (const listener of listeners) {
        listener()
    }
}

export async function readPdf(file) {
    if (file.size > assetByteLimit()) {
        throw new ImportError("tooLarge")
    }
    const bytes = new Uint8Array(await file.arrayBuffer())
    const asset = await assetIdentifier(bytes)
    const document = await openDocument(bytes.slice())
    const isDark = paperStyle() === "dark"
    const pages = []
    const inverted = []
    for (let number = 1; number <= document.numPages; number += 1) {
        const page = await document.getPage(number)
        const viewport = page.getViewport({ scale: 1 })
        pages.push(pageSize(viewport))
        inverted.push(isDark && isWhitePage(await sampleCanvas(page, viewport)))
    }
    await writeAsset(assetPath(asset), bytes)
    documents.set(asset, Promise.resolve(document))
    return { asset, name: file.name, pages, inverted }
}

function pageSize(viewport) {
    return [Math.round(viewport.width * millimetresPerPoint * 100) / 100, Math.round(viewport.height * millimetresPerPoint * 100) / 100]
}

export function importPageSizes(asset) {
    if (pageSizes.has(asset)) {
        return pageSizes.get(asset)
    }
    pageSizes.set(asset, null)
    queue = queue.then(async () => {
        try {
            const pdf = await documentFor(asset)
            const sizes = []
            for (let number = 1; number <= pdf.numPages; number += 1) {
                sizes.push(pageSize((await pdf.getPage(number)).getViewport({ scale: 1 })))
            }
            pageSizes.set(asset, sizes)
        } catch {
            pageSizes.set(asset, [])
        }
        announce()
    })
    return null
}

async function sampleCanvas(page, viewport) {
    const scale = (edgeSampleCount * 2) / Math.max(viewport.width, viewport.height)
    const sampled = page.getViewport({ scale })
    const canvas = document.createElement("canvas")
    canvas.width = Math.max(1, Math.ceil(sampled.width))
    canvas.height = Math.max(1, Math.ceil(sampled.height))
    await page.render({ canvasContext: canvas.getContext("2d"), viewport: sampled }).promise
    return canvas
}

function cachedEntries(element) {
    const prefix = `${element.asset}|${element.source_page}|`
    return [...images.entries()].filter(([key, entry]) => key.startsWith(prefix) && entry.canvas).map(([, entry]) => entry)
}

export function isImportInverted(element, isDark) {
    if (typeof element.inverted === "boolean") {
        return element.inverted
    }
    return isDark && cachedEntries(element).some((entry) => entry.isWhite)
}

function cacheBytes() {
    return tokens.memory.import_cache_megabytes * 1024 * 1024
}

function closeDocument(pending) {
    pending?.then((pdf) => pdf.destroy()).catch(() => {})
}

export function purgeImports() {
    const held = heldKeys()
    for (const key of [...images.keys()]) {
        if (!held.has(key)) {
            images.delete(key)
        }
    }
    queue = queue.then(() => {
        for (const pending of documents.values()) {
            closeDocument(pending)
        }
        documents.clear()
    })
}

export function reloadAssets(assets) {
    if (!assets.length) {
        return
    }
    for (const asset of assets) {
        closeDocument(documents.get(asset))
        documents.delete(asset)
        pageSizes.delete(asset)
        for (const key of [...images.keys()]) {
            if (key.startsWith(`${asset}|`)) {
                images.delete(key)
            }
        }
    }
    announce()
}

function documentFor(asset) {
    let pending = documents.get(asset)
    if (pending) {
        documents.delete(asset)
    } else {
        pending = readAsset(assetPath(asset)).then(openDocument)
    }
    documents.set(asset, pending)
    while (documents.size > Math.max(1, tokens.memory.import_documents)) {
        const [oldest] = documents.keys()
        closeDocument(documents.get(oldest))
        documents.delete(oldest)
    }
    return pending
}

function levelFor(element, pixelsPerMillimetre) {
    const [width, height] = element.source_size_mm
    const needed = pixelsPerMillimetre * Math.max(cellWidth / width, cellHeight / height)
    const level = Math.pow(2, Math.ceil(Math.log2(Math.max(minimumLevel, needed))))
    return Math.min(level, maximumImagePixels / Math.max(width, height))
}

function isWhitePage(canvas) {
    const sample = document.createElement("canvas")
    sample.width = edgeSampleCount
    sample.height = edgeSampleCount
    const context = sample.getContext("2d", { willReadFrequently: true })
    context.drawImage(canvas, 0, 0, edgeSampleCount, edgeSampleCount)
    const pixels = context.getImageData(0, 0, edgeSampleCount, edgeSampleCount).data
    const last = edgeSampleCount - 1
    let white = 0
    let total = 0
    for (let y = 0; y < edgeSampleCount; y += 1) {
        for (let x = 0; x < edgeSampleCount; x += 1) {
            if (x !== 0 && y !== 0 && x !== last && y !== last) {
                continue
            }
            const offset = (y * edgeSampleCount + x) * 4
            const luminance = (0.2126 * pixels[offset] + 0.7152 * pixels[offset + 1] + 0.0722 * pixels[offset + 2]) / 255
            white += luminance >= whiteLuminance ? 1 : 0
            total += 1
        }
    }
    return white / total >= whiteShare
}

function darkened(entry) {
    if (!entry.darkened) {
        const canvas = document.createElement("canvas")
        canvas.width = entry.canvas.width
        canvas.height = entry.canvas.height
        const context = canvas.getContext("2d")
        context.fillStyle = tokens.page.styles.dark.paper
        context.fillRect(0, 0, canvas.width, canvas.height)
        context.globalCompositeOperation = "lighten"
        context.filter = "invert(1) hue-rotate(180deg)"
        context.drawImage(entry.canvas, 0, 0)
        entry.darkened = canvas
    }
    return entry.darkened
}

function entryBytes(entry) {
    return [entry.canvas, entry.darkened].filter(Boolean).reduce((total, canvas) => total + canvas.width * canvas.height * 4, 0)
}

function evict() {
    let total = [...images.values()].reduce((sum, entry) => sum + entryBytes(entry), 0)
    const held = heldKeys()
    const ordered = [...images.entries()].filter(([key, entry]) => entry.canvas && !held.has(key)).sort((first, second) => first[1].lastUsed - second[1].lastUsed)
    for (const [key, entry] of ordered) {
        if (total <= cacheBytes()) {
            break
        }
        total -= entryBytes(entry)
        images.delete(key)
    }
}

function render(key, element, level, isDark) {
    images.set(key, { canvas: null, lastUsed: performance.now() })
    queue = queue.then(async () => {
        try {
            const pdf = await documentFor(element.asset)
            const page = await pdf.getPage(element.source_page + 1)
            const viewport = page.getViewport({ scale: level * millimetresPerPoint })
            const canvas = document.createElement("canvas")
            canvas.width = Math.max(1, Math.ceil(viewport.width))
            canvas.height = Math.max(1, Math.ceil(viewport.height))
            await page.render({ canvasContext: canvas.getContext("2d"), viewport }).promise
            const entry = { canvas, isWhite: isWhitePage(canvas), level, lastUsed: performance.now() }
            if (typeof element.inverted === "boolean" ? element.inverted : isDark && entry.isWhite) {
                darkened(entry)
            }
            images.set(key, entry)
            evict()
            announce()
        } catch (error) {
            images.set(key, { canvas: null, failed: String(error), lastUsed: performance.now() })
        }
    })
}

export function importImage(element, pixelsPerMillimetre, isDark, rendersNewLevel = true, holder = null) {
    if (!element.asset || !element.source_size_mm) {
        return null
    }
    const level = levelFor(element, pixelsPerMillimetre)
    const prefix = `${element.asset}|${element.source_page}|`
    let key = `${prefix}${level}`
    let entry = images.get(key)
    if (!entry && (rendersNewLevel || cachedEntries(element).length === 0)) {
        render(key, element, level, isDark)
        entry = images.get(key)
    }
    if (!entry?.canvas) {
        const nearest = [...images.entries()]
            .filter(([candidate, cached]) => candidate.startsWith(prefix) && cached.canvas)
            .sort((first, second) => Math.abs(first[1].level - level) - Math.abs(second[1].level - level))[0]
        key = nearest?.[0]
        entry = nearest?.[1]
    }
    if (!entry?.canvas) {
        return null
    }
    holder?.add(key)
    entry.lastUsed = performance.now()
    const isInverted = typeof element.inverted === "boolean" ? element.inverted : isDark && entry.isWhite
    return isInverted ? darkened(entry) : entry.canvas
}
