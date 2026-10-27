import CoreImage
import CryptoKit
import NotesCore
import PDFKit
import UIKit

enum ImportError: Error {
    case unreadable
}

final class ImportImages {
    static let shared = ImportImages()
    static let didRender = Notification.Name("ImportImagesDidRender")

    private struct Entry {
        var image: CGImage?
        var darkened: CGImage?
        var isWhite = false
        var level: Double
        var lastUsed: Date
        var isFailed = false
    }

    private static let millimetresPerPoint = 25.4 / 72
    private static let maximumImagePixels = 4096.0
    private static let minimumLevel = 0.5
    private static let cacheLimit = 36
    private static let edgeSampleCount = 48
    private static let whiteLuminance = 0.88
    private static let whiteShare = 0.8

    private let queue = DispatchQueue(label: "com.vaditim.notes.imports", qos: .userInitiated)
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var documents: [String: PDFDocument] = [:]
    private let imageContext = CIContext()
    var assetURL: (String) -> URL = { _ in URL(fileURLWithPath: "/") }

    @MainActor
    static func importDocument(from url: URL, into library: Library) throws -> ImportedDocument {
        let isScoped = url.startAccessingSecurityScopedResource()
        defer {
            if isScoped {
                url.stopAccessingSecurityScopedResource()
            }
        }
        let data = try Data(contentsOf: url)
        guard let document = PDFDocument(data: data), document.pageCount > 0 else {
            throw ImportError.unreadable
        }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let asset = "sha256:\(hash)"
        let target = library.assetURL(asset)
        if !FileManager.default.fileExists(atPath: target.path) {
            try data.write(to: target, options: .atomic)
        }
        let pages: [[Double]] = (0..<document.pageCount).compactMap { index in
            guard let page = document.page(at: index) else { return nil }
            let bounds = page.bounds(for: .mediaBox)
            let isTurned = page.rotation % 180 != 0
            let width = Double(isTurned ? bounds.height : bounds.width) * millimetresPerPoint
            let height = Double(isTurned ? bounds.width : bounds.height) * millimetresPerPoint
            return [(width * 100).rounded() / 100, (height * 100).rounded() / 100]
        }
        return ImportedDocument(asset: asset, pages: pages)
    }

    private func level(for element: Element, pixelsPerMillimetre: Double) -> Double {
        let size = element.sourceSizeMillimetres ?? [210, 297]
        let needed = pixelsPerMillimetre * (element.placement?.scale ?? 1)
        let level = pow(2, ceil(log2(max(Self.minimumLevel, needed))))
        return min(level, Self.maximumImagePixels / max(size[0], size[1]))
    }

    func image(for element: Element, pixelsPerMillimetre: Double, isDark: Bool) -> CGImage? {
        guard let asset = element.asset, element.sourceSizeMillimetres != nil else { return nil }
        let level = level(for: element, pixelsPerMillimetre: pixelsPerMillimetre)
        let prefix = "\(asset)|\(element.sourcePage ?? 0)|"
        let key = "\(prefix)\(level)"
        lock.lock()
        defer { lock.unlock() }
        if entries[key] == nil {
            entries[key] = Entry(level: level, lastUsed: Date())
            render(key: key, element: element, level: level)
        }
        var chosenKey = key
        if entries[key]?.image == nil {
            let fallback = entries
                .filter { $0.key.hasPrefix(prefix) && $0.value.image != nil }
                .min { abs($0.value.level - level) < abs($1.value.level - level) }
            guard let fallback else { return nil }
            chosenKey = fallback.key
        }
        guard var entry = entries[chosenKey], let image = entry.image else { return nil }
        entry.lastUsed = Date()
        if isDark && entry.isWhite {
            if entry.darkened == nil {
                entry.darkened = darkened(image)
            }
            entries[chosenKey] = entry
            return entry.darkened ?? image
        }
        entries[chosenKey] = entry
        return image
    }

    private func render(key: String, element: Element, level: Double) {
        guard let asset = element.asset, let size = element.sourceSizeMillimetres else { return }
        let pageIndex = element.sourcePage ?? 0
        let url = assetURL(asset)
        queue.async { [weak self] in
            guard let self else { return }
            let document = self.documents[asset] ?? PDFDocument(url: url)
            self.documents[asset] = document
            guard let page = document?.page(at: pageIndex) else {
                self.update(key) { $0.isFailed = true }
                return
            }
            let pixelSize = CGSize(width: max(1, (size[0] * level).rounded(.up)), height: max(1, (size[1] * level).rounded(.up)))
            guard let image = page.thumbnail(of: pixelSize, for: .mediaBox).cgImage else {
                self.update(key) { $0.isFailed = true }
                return
            }
            let isWhite = Self.isWhitePage(image)
            self.update(key) { entry in
                entry.image = image
                entry.isWhite = isWhite
            }
            self.evict()
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Self.didRender, object: nil)
            }
        }
    }

    private func update(_ key: String, _ change: (inout Entry) -> Void) {
        lock.lock()
        if var entry = entries[key] {
            change(&entry)
            entries[key] = entry
        }
        lock.unlock()
    }

    private func evict() {
        lock.lock()
        defer { lock.unlock() }
        guard entries.count > Self.cacheLimit else { return }
        let ordered = entries.filter { $0.value.image != nil }.sorted { $0.value.lastUsed < $1.value.lastUsed }
        for (key, _) in ordered.prefix(entries.count - Self.cacheLimit) {
            entries[key] = nil
        }
    }

    private static func isWhitePage(_ image: CGImage) -> Bool {
        let count = edgeSampleCount
        var pixels = [UInt8](repeating: 0, count: count * count * 4)
        guard let context = CGContext(data: &pixels, width: count, height: count, bitsPerComponent: 8, bytesPerRow: count * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: count, height: count))
        var white = 0
        var total = 0
        for y in 0..<count {
            for x in 0..<count where x == 0 || y == 0 || x == count - 1 || y == count - 1 {
                let offset = (y * count + x) * 4
                let luminance = (0.2126 * Double(pixels[offset]) + 0.7152 * Double(pixels[offset + 1]) + 0.0722 * Double(pixels[offset + 2])) / 255
                white += luminance >= whiteLuminance ? 1 : 0
                total += 1
            }
        }
        return Double(white) / Double(max(1, total)) >= whiteShare
    }

    private func darkened(_ image: CGImage) -> CGImage? {
        let source = CIImage(cgImage: image)
        let inverted = source.applyingFilter("CIColorInvert").applyingFilter("CIHueAdjust", parameters: [kCIInputAngleKey: Double.pi])
        let paper = CIColor(color: UIColor(hex: Tokens.shared.page.styles.dark.paper))
        let background = CIImage(color: paper).cropped(to: source.extent)
        let blended = inverted.applyingFilter("CILightenBlendMode", parameters: [kCIInputBackgroundImageKey: background])
        return imageContext.createCGImage(blended, from: source.extent)
    }
}
