import { readAsset, writeAsset } from "./storage.js"
import { tokens } from "./tokens.js"

const millimetresPerPoint = 25.4 / 72
const maximumImagePixels = 4096
const minimumLevel = 0.5
const cacheLimit = 36
const edgeSampleCount = 48
const whiteLuminance = 0.88
const whiteShare = 0.8

const documents = new Map()
const images = new Map()
const listeners = new Set()
let queue = Promise.resolve()
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

function hexOf(buffer) {
    return [...new Uint8Array(buffer)].map((value) => value.toString(16).padStart(2, "0")).join("")
}

export function assetPath(asset) {
    return `assets/${asset.replace("sha256:", "")}.pdf`
}

export function subscribeImports(listener) {
    listeners.add(listener)
    return () => listeners.delete(listener)
}

function announce() {
    for (const listener of listeners) {
        listener()
    }
}

export async function readPdf(file) {
    const bytes = new Uint8Array(await file.arrayBuffer())
    const asset = `sha256:${hexOf(await crypto.subtle.digest("SHA-256", bytes))}`
    const document = await openDocument(bytes.slice())
    const pages = []
    for (let number = 1; number <= document.numPages; number += 1) {
        const viewport = (await document.getPage(number)).getViewport({ scale: 1 })
        pages.push([Math.round(viewport.width * millimetresPerPoint * 100) / 100, Math.round(viewport.height * millimetresPerPoint * 100) / 100])
    }
    await writeAsset(assetPath(asset), bytes)
    documents.set(asset, Promise.resolve(document))
    return { asset, pages }
}

function documentFor(asset) {
    if (!documents.has(asset)) {
        documents.set(asset, readAsset(assetPath(asset)).then(openDocument))
    }
    return documents.get(asset)
}

function levelFor(element, pixelsPerMillimetre) {
    const [width, height] = element.source_size_mm
    const needed = pixelsPerMillimetre * (element.placement?.scale ?? 1)
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

function evict() {
    if (images.size <= cacheLimit) {
        return
    }
    const ordered = [...images.entries()].filter(([, entry]) => entry.canvas).sort((first, second) => first[1].lastUsed - second[1].lastUsed)
    for (const [key] of ordered.slice(0, images.size - cacheLimit)) {
        images.delete(key)
    }
}

function render(key, element, level) {
    images.set(key, { canvas: null, lastUsed: performance.now() })
    queue = queue.then(async () => {
        try {
            const pdf = await documentFor(element.asset)
            const page = await pdf.getPage(element.source_page + 1)
            const viewport = page.getViewport({ scale: level / millimetresPerPoint })
            const canvas = document.createElement("canvas")
            canvas.width = Math.max(1, Math.ceil(viewport.width))
            canvas.height = Math.max(1, Math.ceil(viewport.height))
            await page.render({ canvasContext: canvas.getContext("2d"), viewport }).promise
            images.set(key, { canvas, isWhite: isWhitePage(canvas), level, lastUsed: performance.now() })
            evict()
            announce()
        } catch (error) {
            images.set(key, { canvas: null, failed: String(error), lastUsed: performance.now() })
        }
    })
}

export function importImage(element, pixelsPerMillimetre, isDark) {
    if (!element.asset || !element.source_size_mm) {
        return null
    }
    const level = levelFor(element, pixelsPerMillimetre)
    const prefix = `${element.asset}|${element.source_page}|`
    const key = `${prefix}${level}`
    let entry = images.get(key)
    if (!entry) {
        render(key, element, level)
        entry = images.get(key)
    }
    if (!entry.canvas) {
        entry = [...images.entries()]
            .filter(([candidate, value]) => candidate.startsWith(prefix) && value.canvas)
            .map(([, value]) => value)
            .sort((first, second) => Math.abs(first.level - level) - Math.abs(second.level - level))[0]
    }
    if (!entry?.canvas) {
        return null
    }
    entry.lastUsed = performance.now()
    return isDark && entry.isWhite ? darkened(entry) : entry.canvas
}
