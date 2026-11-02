import { importImage } from "./imports.js"
import { cellHeight, cellWidth, liveElements } from "./model.js"
import { Camera, StrokePathCache, drawPage } from "./renderer.js"
import { exportPdf } from "./storage.js"

const pointsPerMillimetre = 72 / 25.4
const pixelsPerPoint = 4
const maximumPixels = 48_000_000
const renderWaits = 10
const renderWaitMilliseconds = 300

function hasPendingImports(page, pixelsPerMillimetre, isDark) {
    return liveElements(page).some((element) => element.type === "import" && !importImage(element, pixelsPerMillimetre, isDark))
}

function pdfDocument(images, pageWidth, pageHeight) {
    const encoder = new TextEncoder()
    const chunks = []
    const offsets = []
    let length = 0
    const push = (part) => {
        const bytes = typeof part === "string" ? encoder.encode(part) : part
        chunks.push(bytes)
        length += bytes.length
    }
    const object = (number, body, stream) => {
        offsets[number] = length
        push(`${number} 0 obj\n${body}\n`)
        if (stream) {
            push("stream\n")
            push(stream)
            push("\nendstream\n")
        }
        push("endobj\n")
    }
    const width = pageWidth.toFixed(2)
    const height = pageHeight.toFixed(2)
    const contents = encoder.encode(`q ${width} 0 0 ${height} 0 0 cm /Paper Do Q`)
    const pageNumber = (index) => 3 + index * 3
    push("%PDF-1.4\n%âãÏÓ\n")
    object(1, "<< /Type /Catalog /Pages 2 0 R >>")
    object(2, `<< /Type /Pages /Kids [${images.map((_, index) => `${pageNumber(index)} 0 R`).join(" ")}] /Count ${images.length} >>`)
    images.forEach((image, index) => {
        const number = pageNumber(index)
        object(number, `<< /Type /Page /Parent 2 0 R /MediaBox [0 0 ${width} ${height}] /Resources << /XObject << /Paper ${number + 1} 0 R >> >> /Contents ${number + 2} 0 R >>`)
        object(number + 1, `<< /Type /XObject /Subtype /Image /Width ${image.width} /Height ${image.height} /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode /Length ${image.jpeg.length} >>`, image.jpeg)
        object(number + 2, `<< /Length ${contents.length} >>`, contents)
    })
    const count = 3 + images.length * 3
    const xref = length
    push(`xref\n0 ${count}\n0000000000 65535 f \n${offsets.slice(1).map((offset) => `${String(offset).padStart(10, "0")} 00000 n \n`).join("")}`)
    push(`trailer\n<< /Size ${count} /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF\n`)
    const result = new Uint8Array(length)
    let position = 0
    for (const chunk of chunks) {
        result.set(chunk, position)
        position += chunk.length
    }
    return result
}

export async function exportCells(page, title, cells, options) {
    if (!cells.length) {
        return false
    }
    const pageWidth = cellWidth * pointsPerMillimetre
    const pageHeight = cellHeight * pointsPerMillimetre
    const scale = Math.min(pixelsPerPoint, Math.sqrt(maximumPixels / (pageWidth * pageHeight)))
    const width = Math.round(pageWidth * scale)
    const height = Math.round(pageHeight * scale)
    const camera = new Camera(pointsPerMillimetre * scale, 0, 0)
    const isDark = options.paperStyle === "dark"
    for (let attempt = 0; attempt < renderWaits && hasPendingImports(page, camera.scale, isDark); attempt += 1) {
        await new Promise((resolve) => setTimeout(resolve, renderWaitMilliseconds))
    }
    const canvas = document.createElement("canvas")
    canvas.width = width
    canvas.height = height
    const context = canvas.getContext("2d")
    const cache = new StrokePathCache()
    const images = []
    for (const cell of cells) {
        const cellCamera = new Camera(camera.scale, -cell.column * cellWidth * camera.scale, -cell.row * cellHeight * camera.scale)
        drawPage(context, page, cellCamera, { width, height, pixelRatio: 1, ...options, cache })
        const blob = await new Promise((resolve) => canvas.toBlob(resolve, "image/jpeg", 0.92))
        images.push({ jpeg: new Uint8Array(await blob.arrayBuffer()), width, height })
    }
    const name = title.replace(/[/\\:?%*|"<>]/g, " ").trim() || "Note"
    return exportPdf(`${name}.pdf`, pdfDocument(images, pageWidth, pageHeight))
}
