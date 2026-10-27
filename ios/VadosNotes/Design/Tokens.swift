import Foundation

struct Tokens: Decodable {
    struct PaperStyleTokens: Decodable {
        let paper: String
        let guide: String
        let cellBoundary: String
    }

    struct PaperStyles: Decodable {
        let dark: PaperStyleTokens
        let light: PaperStyleTokens
    }

    struct PageTokens: Decodable {
        let cellWidth: Double
        let cellHeight: Double
        let gridSpacing: Double
        let paper: String
        let guide: String
        let cellBoundary: String
        let outside: String
        let defaultStyle: String
        let neutralInkChroma: Double
        let cornerRadius: Double
        let styles: PaperStyles
    }

    struct PaletteTokens: Decodable {
        let ground: String
        let panel: String
        let panelSolid: String
        let sunkenDeep: String
        let sunken: String
        let raised: String
        let border: String
        let borderStrong: String
        let borderControl: String
        let borderHover: String
        let pressedWash: String
        let textPrimary: String
        let textBright: String
        let textBody: String
        let textMuted: String
        let textLabel: String
        let textIcon: String
        let textFaint: String
        let accent: String
    }

    struct SemanticTokens: Decodable {
        let destructive: String
        let destructiveHard: String
        let create: String
        let navigation: String
        let view: String
        let edit: String
        let `import`: String
        let undo: String
        let redo: String
    }

    struct InkToolTokens: Decodable {
        let layer: String
        let width: Double
        let widthRange: [Double]?
        let widthPresets: [Double]?
        let opacity: Double
        let colors: [String]
    }

    struct EraserTokens: Decodable {
        let radius: Double
        let radiusRange: [Double]
        let modes: [String]
    }

    struct ToolTokens: Decodable {
        let pen: InkToolTokens
        let pencil: InkToolTokens
        let marker: InkToolTokens
        let eraser: EraserTokens
    }

    struct InkTokens: Decodable {
        let sampleSpacingPoints: Double
        let smoothingPoints: Double
        let simplifyPoints: Double
        let straightenTolerancePoints: Double
        let straightenAxisSnapDegrees: Double
    }

    struct TextTokens: Decodable {
        let font: String
        let fontSize: Double
        let lineHeight: Double
        let boxWidth: Double
        let color: String
        let fontSizeRange: [Double]
        let fontSizePresets: [Double]
        let colors: [String]
    }

    struct CurveTokens: Decodable {
        let backOut: [Double]
        let backIn: [Double]
        let powerTwoOut: [Double]
        let powerTwoIn: [Double]
        let powerThreeInOut: [Double]
    }

    struct DurationTokens: Decodable {
        let press: Int
        let release: Int
        let state: Int
        let sectionEnter: Int
        let sectionEnterDelay: Int
        let sectionLeave: Int
        let overlayEnter: Int
        let overlayLeave: Int
        let sweepGrow: Int
        let sweepRetract: Int
        let menuHold: Int
        let navSlide: Int
        let navTrail: Int
        let navCarryHold: Int
        let tileDragHold: Int
        let strokeStraightenHold: Int
        let strokeStraightenSnap: Int
        let undo: Int
        let navigationGripHold: Int
        let textMoveHold: Int
        let viewerEnter: Int
        let viewerClose: Int
        let chromeStagger: Int
        let stack: Int
        let riseDelay: Int
        let riseStagger: Int
    }

    struct SpringToken: Decodable {
        let response: Double
        let dampingFraction: Double
    }

    struct SpringTokens: Decodable {
        let placement: SpringToken
        let wash: SpringToken
        let selection: SpringToken
    }

    struct ScaleTokens: Decodable {
        let pressPop: Double
        let held: Double
        let folderEnter: Double
    }

    struct ShareTokens: Decodable {
        let chromeArrival: Double
        let stackStagger: Double
        let flightCornerFade: Double
    }

    struct MotionTokens: Decodable {
        let curves: CurveTokens
        let durations: DurationTokens
        let springs: SpringTokens
        let scales: ScaleTokens
        let shares: ShareTokens
    }

    struct SyncTokens: Decodable {
        let idleSeconds: Double
        let maxAgeSeconds: Double
        let backoffSeconds: [Double]
    }

    struct MenuSlotToken: Decodable {
        let slot: Int
        let action: String
        let role: String
    }

    struct MenuTokens: Decodable {
        let page: [MenuSlotToken]
        let notebook: [MenuSlotToken]
        let pageTile: [MenuSlotToken]
        let grouping: [MenuSlotToken]
        let group: [MenuSlotToken]
    }

    struct FolderTokens: Decodable {
        let defaultColor: String
        let defaultIcon: String
        let noteIcon: String
        let colors: [String]
        let icons: [String]
    }

    private struct GlyphFile: Decodable {
        let glyphs: [String: String]
    }

    let version: Int
    let page: PageTokens
    let palette: PaletteTokens
    let semantic: SemanticTokens
    let tools: ToolTokens
    let ink: InkTokens
    let text: TextTokens
    let motion: MotionTokens
    let sync: SyncTokens
    let menus: MenuTokens
    let folders: FolderTokens
    private(set) var glyphs: [String: String] = [:]

    enum CodingKeys: String, CodingKey {
        case version
        case page
        case palette
        case semantic
        case tools
        case ink
        case text
        case motion
        case sync
        case menus
        case folders
    }

    static let shared: Tokens = {
        guard let url = Bundle.main.url(forResource: "tokens", withExtension: "json") else {
            fatalError("tokens.json is missing from the app bundle")
        }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            var tokens = try decoder.decode(Tokens.self, from: data)
            tokens.glyphs = try JSONDecoder().decode(GlyphFile.self, from: data).glyphs
            return tokens
        } catch {
            fatalError("tokens.json does not decode: \(error)")
        }
    }()
}
