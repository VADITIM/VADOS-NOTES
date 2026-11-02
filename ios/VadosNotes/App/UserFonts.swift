import CoreText
import Foundation
import UIKit

enum UserFontError: Error {
    case unreadable
}

enum UserFonts {
    private static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Fonts", isDirectory: true)
    }

    static func registerStored() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files {
            CTFontManagerRegisterFontsForURL(file as CFURL, .process, nil)
        }
    }

    static func add(from url: URL) throws -> [String] {
        let isScoped = url.startAccessingSecurityScopedResource()
        defer {
            if isScoped {
                url.stopAccessingSecurityScopedResource()
            }
        }
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent(url.lastPathComponent)
        if manager.fileExists(atPath: target.path) {
            CTFontManagerUnregisterFontsForURL(target as CFURL, .process, nil)
            try manager.removeItem(at: target)
        }
        try manager.copyItem(at: url, to: target)
        let descriptors = CTFontManagerCreateFontDescriptorsFromURL(target as CFURL) as? [CTFontDescriptor] ?? []
        let families = Array(Set(descriptors.compactMap { CTFontDescriptorCopyAttribute($0, kCTFontFamilyNameAttribute) as? String })).sorted()
        guard !families.isEmpty else {
            try? manager.removeItem(at: target)
            throw UserFontError.unreadable
        }
        CTFontManagerRegisterFontsForURL(target as CFURL, .process, nil)
        return families
    }

    static var families: [String] {
        let bundled = Tokens.shared.text.fonts
        let installed = UIFont.familyNames.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return bundled + installed.filter { !bundled.contains($0) }
    }

    static func font(family: String, size: CGFloat, isBold: Bool, isItalic: Bool) -> UIFont? {
        var traits: UIFontDescriptor.SymbolicTraits = []
        if isBold {
            traits.insert(.traitBold)
        }
        if isItalic {
            traits.insert(.traitItalic)
        }
        let base = UIFontDescriptor(fontAttributes: [.family: family])
        let font = UIFont(descriptor: base.withSymbolicTraits(traits) ?? base, size: size)
        return font.familyName == family ? font : nil
    }
}
