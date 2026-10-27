import Foundation
import NotesCore

enum ActiveTool: String, CaseIterable {
    case pen
    case marker
    case eraser
    case text

    static let drawing: [ActiveTool] = [.pen, .marker]

    var inkTool: Tool? {
        switch self {
        case .pen: return .pen
        case .marker: return .marker
        default: return nil
        }
    }
}

enum EraserMode: String {
    case stroke
    case area
}

enum NavOrientation: String {
    case horizontal
    case vertical
}

struct NavPlacement: Codable, Equatable {
    var x: Double
    var y: Double
    var orientation: String
}

@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()

    private let defaults = UserDefaults.standard
    private let tokens = Tokens.shared
    @Published private(set) var revision = 0

    private func read<Value>(_ key: String, _ fallback: Value) -> Value {
        defaults.object(forKey: key) as? Value ?? fallback
    }

    private func write(_ key: String, _ value: Any?) {
        defaults.set(value, forKey: key)
        revision += 1
    }

    private func clamp(_ value: Double, _ range: [Double]) -> Double {
        min(range[1], max(range[0], value))
    }

    nonisolated static func inkTokens(_ tool: Tool) -> Tokens.InkToolTokens {
        switch tool {
        case .pen: return Tokens.shared.tools.pen
        case .pencil: return Tokens.shared.tools.pencil
        case .marker: return Tokens.shared.tools.marker
        }
    }

    private func widthRange(_ tool: Tool) -> [Double] {
        Self.inkTokens(tool).widthRange ?? [0.1, 20]
    }

    var paperStyle: PaperStyle {
        PaperStyle(rawValue: read("paperStyle", tokens.page.defaultStyle)) ?? .dark
    }

    func setPaperStyle(_ style: PaperStyle) {
        write("paperStyle", style.rawValue)
    }

    var showsGuides: Bool {
        read("showsGuides", true)
    }

    var showsDividers: Bool {
        read("showsDividers", true)
    }

    func setShowsGuides(_ value: Bool) {
        write("showsGuides", value)
    }

    func setShowsDividers(_ value: Bool) {
        write("showsDividers", value)
    }

    var activeTool: ActiveTool {
        ActiveTool(rawValue: read("activeTool", "pen")) ?? .pen
    }

    func setActiveTool(_ tool: ActiveTool) {
        write("activeTool", tool.rawValue)
    }

    func color(_ tool: Tool) -> String {
        read("\(tool.rawValue)Color", Self.inkTokens(tool).colors[0])
    }

    func setColor(_ color: String, for tool: Tool) {
        write("\(tool.rawValue)Color", color.uppercased())
    }

    func width(_ tool: Tool) -> Double {
        clamp(read("\(tool.rawValue)Width", Self.inkTokens(tool).width), widthRange(tool))
    }

    func setWidth(_ width: Double, for tool: Tool) {
        write("\(tool.rawValue)Width", clamp(width, widthRange(tool)))
    }

    static func roundedWidth(_ width: Double) -> Double {
        (width * 100).rounded() / 100
    }

    static func isSameWidth(_ first: Double, _ second: Double) -> Bool {
        roundedWidth(first) == roundedWidth(second)
    }

    func widthPresets(_ tool: Tool) -> [Double] {
        read("\(tool.rawValue)WidthPresets", Self.inkTokens(tool).widthPresets ?? [])
    }

    func addWidthPreset(_ width: Double, for tool: Tool) {
        let rounded = Self.roundedWidth(clamp(width, widthRange(tool)))
        let presets = widthPresets(tool)
        guard !presets.contains(where: { Self.isSameWidth($0, rounded) }) else { return }
        write("\(tool.rawValue)WidthPresets", (presets + [rounded]).sorted())
    }

    func removeWidthPreset(_ width: Double, for tool: Tool) {
        write("\(tool.rawValue)WidthPresets", widthPresets(tool).filter { $0 != width })
    }

    func colorPresets(_ tool: Tool) -> [String] {
        read("\(tool.rawValue)Presets", Self.inkTokens(tool).colors)
    }

    func addColorPreset(_ color: String, for tool: Tool) {
        let normalized = color.uppercased()
        let presets = colorPresets(tool)
        guard !presets.contains(normalized) else { return }
        write("\(tool.rawValue)Presets", presets + [normalized])
    }

    func removeColorPreset(_ color: String, for tool: Tool) {
        write("\(tool.rawValue)Presets", colorPresets(tool).filter { $0 != color })
    }

    var eraserRadius: Double {
        clamp(read("eraserRadius", tokens.tools.eraser.radius), tokens.tools.eraser.radiusRange)
    }

    func setEraserRadius(_ radius: Double) {
        write("eraserRadius", clamp(radius, tokens.tools.eraser.radiusRange))
    }

    var eraserMode: EraserMode {
        EraserMode(rawValue: read("eraserMode", tokens.tools.eraser.modes[0])) ?? .stroke
    }

    func setEraserMode(_ mode: EraserMode) {
        write("eraserMode", mode.rawValue)
    }

    var textFontSize: Double {
        clamp(read("textFontSize", tokens.text.fontSize), tokens.text.fontSizeRange)
    }

    func setTextFontSize(_ size: Double) {
        write("textFontSize", clamp(size, tokens.text.fontSizeRange))
    }

    var navPlacement: NavPlacement? {
        guard let data = defaults.data(forKey: "navPlacement") else { return nil }
        return try? JSONDecoder().decode(NavPlacement.self, from: data)
    }

    func setNavPlacement(_ placement: NavPlacement) {
        defaults.set(try? JSONEncoder().encode(placement), forKey: "navPlacement")
    }
}
