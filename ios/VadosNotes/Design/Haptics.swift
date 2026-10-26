import UIKit

enum Haptics {
    private static let tickGenerator = UIImpactFeedbackGenerator(style: .light)
    private static let holdGenerator = UIImpactFeedbackGenerator(style: .medium)
    private static let selectionGenerator = UISelectionFeedbackGenerator()
    private static let confirmGapSeconds = 0.07

    static func tick() {
        tickGenerator.impactOccurred()
    }

    static func hold() {
        holdGenerator.impactOccurred()
    }

    static func segment() {
        selectionGenerator.selectionChanged()
    }

    static func landed() {
        tickGenerator.impactOccurred()
        DispatchQueue.main.asyncAfter(deadline: .now() + confirmGapSeconds) {
            tickGenerator.impactOccurred()
        }
    }
}
