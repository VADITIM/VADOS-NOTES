import SwiftUI
import UIKit

enum MenuRole: String {
    case destructive
    case create
    case navigation
    case view
    case edit
    case importAsset = "import"
    case ink
}

enum Palette {
    private static let tokens = Tokens.shared

    static let ground = Color(hex: tokens.palette.ground)
    static let panel = Color(hex: tokens.palette.panel)
    static let panelSolid = Color(hex: tokens.palette.panelSolid)
    static let sunkenDeep = Color(hex: tokens.palette.sunkenDeep)
    static let sunken = Color(hex: tokens.palette.sunken)
    static let raised = Color(hex: tokens.palette.raised)
    static let border = Color(hex: tokens.palette.border)
    static let borderStrong = Color(hex: tokens.palette.borderStrong)
    static let borderControl = Color(hex: tokens.palette.borderControl)
    static let borderHover = Color(hex: tokens.palette.borderHover)
    static let pressedWash = Color(hex: tokens.palette.pressedWash)
    static let textPrimary = Color(hex: tokens.palette.textPrimary)
    static let textBright = Color(hex: tokens.palette.textBright)
    static let textBody = Color(hex: tokens.palette.textBody)
    static let textMuted = Color(hex: tokens.palette.textMuted)
    static let textLabel = Color(hex: tokens.palette.textLabel)
    static let textIcon = Color(hex: tokens.palette.textIcon)
    static let textFaint = Color(hex: tokens.palette.textFaint)
    static let accent = Color(hex: tokens.palette.accent)

    static let destructive = Color(hex: tokens.semantic.destructive)
    static let destructiveHard = Color(hex: tokens.semantic.destructiveHard)
    static let create = Color(hex: tokens.semantic.create)
    static let navigation = Color(hex: tokens.semantic.navigation)
    static let view = Color(hex: tokens.semantic.view)
    static let edit = Color(hex: tokens.semantic.edit)
    static let importAsset = Color(hex: tokens.semantic.import)

    static let outside = UIColor(hex: tokens.page.outside)

    static func paperColors(_ style: PaperStyle) -> Tokens.PaperStyleTokens {
        style == .dark ? tokens.page.styles.dark : tokens.page.styles.light
    }

    static func isNeutral(_ hex: String) -> Bool {
        let components = HexColor.components(hex)
        let values = [components.red, components.green, components.blue]
        return (values.max() ?? 0) - (values.min() ?? 0) <= tokens.page.neutralInkChroma
    }

    static func inkOnPaper(_ hex: String, style: PaperStyle) -> String {
        guard style == .dark, isNeutral(hex) else { return hex }
        let components = HexColor.components(hex)
        return HexColor.hex(red: 1 - components.red, green: 1 - components.green, blue: 1 - components.blue, alpha: components.alpha)
    }

    static func color(for role: MenuRole) -> Color {
        switch role {
        case .destructive: return destructive
        case .create: return create
        case .navigation: return navigation
        case .view: return view
        case .edit: return edit
        case .importAsset: return importAsset
        case .ink: return textBright
        }
    }

    static func isLight(_ hex: String) -> Bool {
        let components = HexColor.components(hex)
        return components.red * 0.299 + components.green * 0.587 + components.blue * 0.114 > 0.5
    }
}

enum PaperStyle: String, CaseIterable {
    case dark
    case light
}

enum HexColor {
    static func hex(red: Double, green: Double, blue: Double, alpha: Double = 1) -> String {
        func byte(_ value: Double) -> String {
            String(format: "%02X", Int((min(1, max(0, value)) * 255).rounded()))
        }
        return "#\(byte(red))\(byte(green))\(byte(blue))\(alpha < 1 ? byte(alpha) : "")"
    }

    static func components(_ hex: String) -> (red: Double, green: Double, blue: Double, alpha: Double) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") {
            text.removeFirst()
        }
        guard text.count == 6 || text.count == 8, let value = UInt64(text, radix: 16) else {
            return (0, 0, 0, 1)
        }
        if text.count == 6 {
            return (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255, 1)
        }
        return (Double((value >> 24) & 0xFF) / 255, Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
    }
}

extension Color {
    init(hex: String) {
        let components = HexColor.components(hex)
        self.init(.sRGB, red: components.red, green: components.green, blue: components.blue, opacity: components.alpha)
    }
}

extension UIColor {
    convenience init(hex: String) {
        let components = HexColor.components(hex)
        self.init(red: components.red, green: components.green, blue: components.blue, alpha: components.alpha)
    }
}
