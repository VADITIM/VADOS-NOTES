import SwiftUI
import UIKit

enum Typography {
    static let monoName = "SpaceMono-Regular"
    static let monoBoldName = "SpaceMono-Bold"
    static let headingName = "Audiowide-Regular"

    static func mono(_ size: CGFloat) -> Font {
        .custom(monoName, fixedSize: size)
    }

    static func monoBold(_ size: CGFloat) -> Font {
        .custom(monoBoldName, fixedSize: size)
    }

    static func heading(_ size: CGFloat) -> Font {
        .custom(headingName, fixedSize: size)
    }

    static func monoFont(_ size: CGFloat) -> UIFont {
        UIFont(name: monoName, size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    }
}

struct MicroLabel: View {
    let text: String
    var color: Color = Palette.textLabel

    var body: some View {
        Text(text.uppercased())
            .font(Typography.mono(10))
            .tracking(3)
            .foregroundColor(color)
            .lineLimit(1)
    }
}
