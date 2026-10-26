import Foundation

struct Tokens: Decodable {
    struct PageTokens: Decodable {
        let cellWidth: Double
        let cellHeight: Double
        let gridSpacing: Double
        let paper: String
        let guide: String
        let cellBoundary: String
        let outside: String
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
    }

    struct InkToolTokens: Decodable {
        let layer: String
        let width: Double
        let opacity: Double
        let colors: [String]
    }

    struct EraserTokens: Decodable {
        let radius: Double
    }

    struct ToolTokens: Decodable {
        let pen: InkToolTokens
        let pencil: InkToolTokens
        let marker: InkToolTokens
        let eraser: EraserTokens
    }

    struct TextTokens: Decodable {
        let font: String
        let fontSize: Double
        let lineHeight: Double
        let boxWidth: Double
        let color: String
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
        let undo: Int
    }

    struct MotionTokens: Decodable {
        let curves: CurveTokens
        let durations: DurationTokens
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
        let columns: Int
        let page: [MenuSlotToken]
        let notebook: [MenuSlotToken]
        let pageTile: [MenuSlotToken]
    }

    let version: Int
    let page: PageTokens
    let palette: PaletteTokens
    let semantic: SemanticTokens
    let tools: ToolTokens
    let text: TextTokens
    let motion: MotionTokens
    let sync: SyncTokens
    let menus: MenuTokens

    static let shared: Tokens = {
        guard let url = Bundle.main.url(forResource: "tokens", withExtension: "json") else {
            fatalError("tokens.json is missing from the app bundle")
        }
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(Tokens.self, from: Data(contentsOf: url))
        } catch {
            fatalError("tokens.json does not decode: \(error)")
        }
    }()
}
