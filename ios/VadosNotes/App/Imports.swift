import CoreImage
import NotesCore
import PDFKit
import UIKit

enum ImportError: Error {
    case unreadable
    case tooLarge(megabytes: Int)

    static func message(for error: Error) -> String {
        switch error {
        case ImportError.tooLarge(let megabytes):
            return "Larger than \(megabytes) MB"
        default:
            return "Not a readable PDF"
        }
    }
}

final class ImportImages {
    static let shared = ImportImages()
    static let didRender = Notification.Name("ImportImagesDidRender")
    private(set) static var revision = 0

    private struct Entry {
        var image: CGImage?
        var darkened: CGImage?
        var isWhite = false
        var level: Double
        var lastUsed: Date
        var isFailed = false
        var isDarkening = false
    }

    private static let millimetresPerPoint = 25.4 / 72
    private static let maximumImagePixels = 4096.0
    private static let minimumLevel = 0.5
    private static let edgeSampleCount = 48
    private static let whiteLuminance = 0.88
    private static let whiteShare = 0.8

    private let queue = DispatchQueue(label: "com.vaditim.notes.imports", qos: .userInitiated)
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var documents: [String: PDFDocument] = [:]
    private var documentOrder: [String] = []
    private let imageContext = CIContext()
    var assetURL: (String) -> URL? = { _ in nil }

    private static var cacheBytes: Int {
        Tokens.shared.memory.importCacheMegabytes * 1024 * 1024
    }

    private init() {
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil) { [weak self] _ in
            self?.purge()
        }
    }

    func purge() {
        lock.lock()
        entries = [:]
        lock.unlock()
        queue.async { [weak self] in
            self?.documents = [:]
            self?.documentOrder = []
        }
    }

    private func document(for asset: String, at url: URL?) -> PDFDocument? {
        if let document = documents[asset] {
            documentOrder.removeAll { $0 == asset }
            documentOrder.append(asset)
            return document
        }
        guard let document = url.flatMap({ PDFDocument(url: $0) }) else { return nil }
        documents[asset] = document
        documentOrder.append(asset)
        while documentOrder.count > max(1, Tokens.shared.memory.importDocuments) {
            documents[documentOrder.removeFirst()] = nil
        }
        return document
    }

    @MainActor
    static func importDocument(from url: URL, into library: Library) throws -> ImportedDocument {
        let isScoped = url.startAccessingSecurityScopedResource()
        defer {
            if isScoped {
                url.stopAccessingSecurityScopedResource()
            }
        }
        let data = try Data(contentsOf: url)
        let byteLimit = library.store.assets.byteLimit
        guard data.count <= byteLimit else {
            throw ImportError.tooLarge(megabytes: byteLimit / (1024 * 1024))
        }
        guard let document = PDFDocument(data: data), document.pageCount > 0 else {
            throw ImportError.unreadable
        }
        let asset = try library.store.assets.add(data)
        let isDark = Preferences.shared.paperStyle == .dark
        var pages: [[Double]] = []
        var inverted: [Bool] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            let isTurned = page.rotation % 180 != 0
            let width = Double(isTurned ? bounds.height : bounds.width) * millimetresPerPoint
            let height = Double(isTurned ? bounds.width : bounds.height) * millimetresPerPoint
            pages.append([(width * 100).rounded() / 100, (height * 100).rounded() / 100])
            let sample = flattened(page, pixelSize: CGSize(width: edgeSampleCount * 2, height: edgeSampleCount * 2))
            inverted.append(isDark && sample.map(isWhitePage) == true)
        }
        return ImportedDocument(asset: asset, pages: pages, inverted: inverted)
    }

    private static func flattened(_ page: PDFPage, pixelSize: CGSize) -> CGImage? {
        let thumbnail = page.thumbnail(of: pixelSize, for: .mediaBox)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: pixelSize, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: pixelSize))
            thumbnail.draw(in: CGRect(origin: .zero, size: pixelSize))
        }.cgImage
    }

    func isInverted(_ element: Element, isDark: Bool) -> Bool {
        if let inverted = element.inverted {
            return inverted
        }
        guard isDark, let asset = element.asset else { return false }
        let prefix = "\(asset)|\(element.sourcePage ?? 0)|"
        lock.lock()
        defer { lock.unlock() }
        return entries.contains { $0.key.hasPrefix(prefix) && $0.value.isWhite }
    }

    private func level(for element: Element, pixelsPerMillimetre: Double) -> Double {
        let size = element.sourceSizeMillimetres ?? [210, 297]
        let needed = pixelsPerMillimetre * max(PaperGeometry.cellWidth / size[0], PaperGeometry.cellHeight / size[1])
        let level = pow(2, ceil(log2(max(Self.minimumLevel, needed))))
        return min(level, Self.maximumImagePixels / max(size[0], size[1]))
    }

    func image(for element: Element, pixelsPerMillimetre: Double, isDark: Bool, rendersNewLevel: Bool = true) -> CGImage? {
        guard let asset = element.asset, element.sourceSizeMillimetres != nil else { return nil }
        let level = level(for: element, pixelsPerMillimetre: pixelsPerMillimetre)
        let prefix = "\(asset)|\(element.sourcePage ?? 0)|"
        let key = "\(prefix)\(level)"
        lock.lock()
        defer { lock.unlock() }
        if entries[key] == nil, rendersNewLevel || !entries.contains(where: { $0.key.hasPrefix(prefix) && $0.value.image != nil }) {
            entries[key] = Entry(level: level, lastUsed: Date())
            render(key: key, element: element, level: level, isDark: isDark)
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
        entries[chosenKey] = entry
        guard element.inverted ?? (isDark && entry.isWhite) else { return image }
        if let darkened = entry.darkened {
            return darkened
        }
        darken(key: chosenKey, image: image)
        return image
    }

    private func darken(key: String, image: CGImage) {
        guard entries[key]?.isDarkening == false else { return }
        entries[key]?.isDarkening = true
        queue.async { [weak self] in
            guard let self else { return }
            let darkened = self.darkened(image) ?? image
            self.update(key) { entry in
                entry.darkened = darkened
                entry.isDarkening = false
            }
            Self.announce(key)
        }
    }

    private func render(key: String, element: Element, level: Double, isDark: Bool) {
        guard let asset = element.asset, let size = element.sourceSizeMillimetres else { return }
        let pageIndex = element.sourcePage ?? 0
        let url = assetURL(asset)
        queue.async { [weak self] in
            guard let self else { return }
            guard let page = self.document(for: asset, at: url)?.page(at: pageIndex) else {
                self.update(key) { $0.isFailed = true }
                return
            }
            let pixelSize = CGSize(width: max(1, (size[0] * level).rounded(.up)), height: max(1, (size[1] * level).rounded(.up)))
            guard let image = Self.flattened(page, pixelSize: pixelSize) else {
                self.update(key) { $0.isFailed = true }
                return
            }
            let isWhite = Self.isWhitePage(image)
            let darkened = element.inverted ?? (isDark && isWhite) ? self.darkened(image) : nil
            self.update(key) { entry in
                entry.image = image
                entry.darkened = darkened
                entry.isWhite = isWhite
            }
            self.evict()
            Self.announce(asset)
        }
    }

    private static func announce(_ key: String) {
        let asset = String(key.prefix { $0 != "|" })
        DispatchQueue.main.async {
            revision += 1
            NotificationCenter.default.post(name: didRender, object: asset as NSString)
        }
    }

    static func isAnnounced(_ notification: Notification, for page: Page) -> Bool {
        guard let asset = notification.object as? String else { return true }
        return page.elements.contains { $0.type == .importPage && $0.asset == asset }
    }

    func reload(assets: [String]) {
        guard !assets.isEmpty else { return }
        queue.async { [weak self] in
            guard let self else { return }
            for asset in assets {
                self.documents[asset] = nil
            }
            self.documentOrder.removeAll { assets.contains($0) }
            self.lock.lock()
            self.entries = self.entries.filter { key, _ in !assets.contains { key.hasPrefix("\($0)|") } }
            self.lock.unlock()
            DispatchQueue.main.async {
                Self.revision += 1
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
        func bytes(_ entry: Entry) -> Int {
            [entry.image, entry.darkened].compactMap { $0 }.reduce(0) { $0 + $1.bytesPerRow * $1.height }
        }
        var total = entries.values.reduce(0) { $0 + bytes($1) }
        let ordered = entries.filter { $0.value.image != nil }.sorted { $0.value.lastUsed < $1.value.lastUsed }
        for (key, entry) in ordered where total > Self.cacheBytes {
            total -= bytes(entry)
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
