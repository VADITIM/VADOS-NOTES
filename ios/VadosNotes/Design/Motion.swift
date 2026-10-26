import SwiftUI

enum Motion {
    private static let curves = Tokens.shared.motion.curves
    private static let durations = Tokens.shared.motion.durations

    static let pressMilliseconds = durations.press
    static let releaseMilliseconds = durations.release
    static let stateMilliseconds = durations.state
    static let sectionEnterMilliseconds = durations.sectionEnter
    static let sectionEnterDelayMilliseconds = durations.sectionEnterDelay
    static let sectionLeaveMilliseconds = durations.sectionLeave
    static let overlayEnterMilliseconds = durations.overlayEnter
    static let overlayLeaveMilliseconds = durations.overlayLeave
    static let sweepGrowMilliseconds = durations.sweepGrow
    static let sweepRetractMilliseconds = durations.sweepRetract
    static let menuHoldMilliseconds = durations.menuHold

    static func backOut(_ milliseconds: Int, delay: Int = 0) -> Animation {
        animation(curves.backOut, milliseconds, delay)
    }

    static func backIn(_ milliseconds: Int, delay: Int = 0) -> Animation {
        animation(curves.backIn, milliseconds, delay)
    }

    static func powerTwoOut(_ milliseconds: Int, delay: Int = 0) -> Animation {
        animation(curves.powerTwoOut, milliseconds, delay)
    }

    static func powerTwoIn(_ milliseconds: Int, delay: Int = 0) -> Animation {
        animation(curves.powerTwoIn, milliseconds, delay)
    }

    static func powerThreeInOut(_ milliseconds: Int, delay: Int = 0) -> Animation {
        animation(curves.powerThreeInOut, milliseconds, delay)
    }

    static func seconds(_ milliseconds: Int) -> Double {
        Double(milliseconds) / 1000
    }

    private static func animation(_ curve: [Double], _ milliseconds: Int, _ delay: Int) -> Animation {
        Animation.timingCurve(curve[0], curve[1], curve[2], curve[3], duration: seconds(milliseconds)).delay(seconds(delay))
    }
}

extension AnyTransition {
    static let pop: AnyTransition = .asymmetric(
        insertion: AnyTransition.scale(scale: 0.001).combined(with: .opacity).animation(Motion.backOut(Motion.stateMilliseconds, delay: Motion.stateMilliseconds)),
        removal: AnyTransition.scale(scale: 0.001).combined(with: .opacity).animation(Motion.backIn(Motion.stateMilliseconds))
    )

    static let section: AnyTransition = .asymmetric(
        insertion: AnyTransition.opacity.combined(with: .scale(scale: 0.96)).animation(Motion.powerTwoOut(Motion.sectionEnterMilliseconds, delay: Motion.sectionEnterDelayMilliseconds)),
        removal: AnyTransition.opacity.animation(Motion.powerTwoIn(Motion.sectionLeaveMilliseconds))
    )

    static let overlay: AnyTransition = .asymmetric(
        insertion: AnyTransition.opacity.combined(with: .scale(scale: 0.94)).combined(with: .offset(y: 24)).animation(Motion.backOut(Motion.overlayEnterMilliseconds)),
        removal: AnyTransition.opacity.combined(with: .scale(scale: 0.96)).animation(Motion.powerTwoIn(Motion.overlayLeaveMilliseconds))
    )
}
