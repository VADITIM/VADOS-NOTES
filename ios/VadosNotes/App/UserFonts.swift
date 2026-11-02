import CoreText
import Foundation
import SwiftUI
import UIKit

enum UserFontError: Error {
    case unreadable
}

enum UserFonts {
    private static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Fonts", isDirectory: true)
    }

    private static var stored: [String] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return files.flatMap { file in
            (CTFontManagerCreateFontDescriptorsFromURL(file as CFURL) as? [CTFontDescriptor] ?? []).compactMap { CTFontDescriptorCopyAttribute($0, kCTFontFamilyNameAttribute) as? String }
        }
    }

    static func adopt(_ descriptor: UIFontDescriptor) -> String? {
        let family = descriptor.object(forKey: .family) as? String ?? UIFont(descriptor: descriptor, size: 16).familyName
        if let url = CTFontDescriptorCopyAttribute(descriptor as CTFontDescriptor, kCTFontURLAttribute) as? URL, !url.path.hasPrefix("/System") {
            _ = try? add(from: url)
        }
        return family.isEmpty ? nil : family
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
        let available = CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? []
        let installed = Set(UIFont.familyNames + available + stored)
            .filter { !$0.hasPrefix(".") && !bundled.contains($0) }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return bundled + installed
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

struct SystemFontPicker: UIViewControllerRepresentable {
    let onPick: (String?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    func makeUIViewController(context: Context) -> UIFontPickerViewController {
        let configuration = UIFontPickerViewController.Configuration()
        configuration.includeFaces = false
        configuration.displayUsingSystemFont = false
        let picker = UIFontPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIFontPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIFontPickerViewControllerDelegate {
        let onPick: (String?) -> Void

        init(onPick: @escaping (String?) -> Void) {
            self.onPick = onPick
        }

        func fontPickerViewControllerDidPickFont(_ picker: UIFontPickerViewController) {
            onPick(picker.selectedFontDescriptor.flatMap(UserFonts.adopt))
        }

        func fontPickerViewControllerDidCancel(_ picker: UIFontPickerViewController) {
            onPick(nil)
        }
    }
}
