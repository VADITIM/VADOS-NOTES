import SwiftUI

enum Motion {
    private static let curves = Tokens.shared.motion.curves
    private static let durations = Tokens.shared.motion.durations
    private static let springs = Tokens.shared.motion.springs
    static let scales = Tokens.shared.motion.scales
    static let shares = Tokens.shared.motion.shares

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
    static let navigationGripHoldMilliseconds = durations.navigationGripHold
    static let textMoveHoldMilliseconds = durations.textMoveHold
    static let viewerEnterMilliseconds = durations.viewerEnter
    static let viewerCloseMilliseconds = durations.viewerClose
    static let chromeStaggerMilliseconds = durations.chromeStagger
    static let stackMilliseconds = durations.stack
    static let riseDelayMilliseconds = durations.riseDelay
    static let riseStaggerMilliseconds = durations.riseStagger
    static let sheetDropMilliseconds = durations.sheetDrop

    static var placement: Animation { spring(springs.placement) }
    static var wash: Animation { spring(springs.wash) }
    static var selection: Animation { spring(springs.selection) }

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

    static func backOutValue(_ progress: CGFloat) -> CGFloat {
        eased(curves.backOut, progress)
    }

    static func powerThreeInOutValue(_ progress: CGFloat) -> CGFloat {
        eased(curves.powerThreeInOut, progress)
    }

    private static func eased(_ curve: [Double], _ progress: CGFloat) -> CGFloat {
        let target = Double(min(1, max(0, progress)))
        func bezier(_ first: Double, _ second: Double, _ parameter: Double) -> Double {
            let inverse = 1 - parameter
            return 3 * inverse * inverse * parameter * first + 3 * inverse * parameter * parameter * second + parameter * parameter * parameter
        }
        var lower = 0.0
        var upper = 1.0
        var parameter = target
        for _ in 0..<24 {
            parameter = (lower + upper) / 2
            if bezier(curve[0], curve[2], parameter) < target {
                lower = parameter
            } else {
                upper = parameter
            }
        }
        return CGFloat(bezier(curve[1], curve[3], parameter))
    }

    static func seconds(_ milliseconds: Int) -> Double {
        Double(milliseconds) / 1000
    }

    private static func spring(_ token: Tokens.SpringToken) -> Animation {
        .spring(response: token.response, dampingFraction: token.dampingFraction)
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

    static let popTogether: AnyTransition = .asymmetric(
        insertion: AnyTransition.scale(scale: 0.001).combined(with: .opacity).animation(Motion.backOut(Motion.stateMilliseconds)),
        removal: AnyTransition.scale(scale: 0.001).combined(with: .opacity).animation(Motion.backIn(Motion.stateMilliseconds))
    )

    static let folder: AnyTransition = .asymmetric(
        insertion: AnyTransition.opacity.combined(with: .scale(scale: Motion.scales.folderEnter)).animation(Motion.powerTwoOut(Motion.sectionEnterMilliseconds, delay: Motion.sectionEnterDelayMilliseconds)),
        removal: AnyTransition.opacity.animation(Motion.powerTwoIn(Motion.sectionLeaveMilliseconds))
    )

    static let fromTopEdge: AnyTransition = .asymmetric(
        insertion: AnyTransition.move(edge: .top).animation(Motion.backOut(Motion.sheetDropMilliseconds)),
        removal: AnyTransition.move(edge: .top).animation(Motion.backIn(Motion.sheetDropMilliseconds))
    )

    static let rotatePop: AnyTransition = .asymmetric(
        insertion: AnyTransition.modifier(active: RotatePop(isShown: false), identity: RotatePop(isShown: true)).animation(Motion.backOut(Motion.stateMilliseconds, delay: Motion.stateMilliseconds)),
        removal: AnyTransition.modifier(active: RotatePop(isShown: false), identity: RotatePop(isShown: true)).animation(Motion.backIn(Motion.stateMilliseconds))
    )

    static let flight: AnyTransition = .asymmetric(
        insertion: .identity,
        removal: AnyTransition.opacity.animation(Motion.powerTwoIn(Motion.sectionLeaveMilliseconds))
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

struct RotatePop: ViewModifier {
    let isShown: Bool

    static let turn = Angle.degrees(-90)

    func body(content: Content) -> some View {
        content
            .scaleEffect(isShown ? 1 : 0.001)
            .rotationEffect(isShown ? .zero : Self.turn)
            .opacity(isShown ? 1 : 0)
    }
}

struct StaggeredRotatePop: ViewModifier {
    let isShown: Bool
    let order: Int
    let count: Int
    let enterDelay: Int

    func body(content: Content) -> some View {
        content
            .modifier(RotatePop(isShown: isShown))
            .animation(
                isShown
                    ? Motion.backOut(Motion.stateMilliseconds, delay: enterDelay + order * Motion.chromeStaggerMilliseconds)
                    : Motion.backIn(Motion.stateMilliseconds, delay: (count - 1 - order) * Motion.chromeStaggerMilliseconds),
                value: isShown
            )
    }
}

struct HoldPop: ViewModifier {
    let isPressed: Bool
    var isHoldable = true

    @State private var isHeld = false
    @State private var holdWork: DispatchWorkItem?

    private var scale: CGFloat {
        if isHeld { return CGFloat(Motion.scales.holdPop) }
        if isPressed { return isHoldable ? CGFloat(Motion.scales.holdGrow) : CGFloat(Motion.scales.pressPop) }
        return 1
    }

    private var animation: Animation {
        if isHeld { return Motion.backOut(Motion.stateMilliseconds) }
        if isPressed { return isHoldable ? .linear(duration: Motion.seconds(Motion.menuHoldMilliseconds)) : Motion.powerTwoOut(Motion.pressMilliseconds) }
        return Motion.backOut(Motion.releaseMilliseconds)
    }

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale)
            .animation(animation, value: scale)
            .onChange(of: isPressed) { _, pressed in
                holdWork?.cancel()
                guard pressed, isHoldable else {
                    isHeld = false
                    return
                }
                let work = DispatchWorkItem { isHeld = true }
                holdWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + Motion.seconds(Motion.menuHoldMilliseconds), execute: work)
            }
    }
}

struct ChromePop: ViewModifier {
    let isShown: Bool
    let order: Int
    let anchor: UnitPoint

    func body(content: Content) -> some View {
        content
            .scaleEffect(isShown ? 1 : 0.001, anchor: anchor)
            .opacity(isShown ? 1 : 0)
            .animation(
                isShown ? Motion.backOut(Motion.stateMilliseconds, delay: order * Motion.chromeStaggerMilliseconds) : Motion.backIn(Motion.stateMilliseconds),
                value: isShown
            )
    }
}

struct TileFlight: ViewModifier, Animatable {
    var progress: CGFloat
    let tile: CGRect?

    private static let tileRadius: CGFloat = 18
    private static let openRadius: CGFloat = 24

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        GeometryReader { proxy in
            let full = CGRect(origin: .zero, size: proxy.size)
            let origin = proxy.frame(in: .global).origin
            let start = tile?.offsetBy(dx: -origin.x, dy: -origin.y) ?? full
            let shown = tile == nil ? 1 : progress
            let frame = CGRect(
                x: start.minX + (full.minX - start.minX) * shown,
                y: start.minY + (full.minY - start.minY) * shown,
                width: start.width + (full.width - start.width) * shown,
                height: start.height + (full.height - start.height) * shown
            )
            let cover = max(start.width / max(1, full.width), start.height / max(1, full.height))
            let scale = cover + (1 - cover) * shown
            let fade = CGFloat(Motion.shares.flightCornerFade)
            let expand = min(1, max(0, (shown - (1 - fade)) / fade))
            let radius = (Self.tileRadius + (Self.openRadius - Self.tileRadius) * shown) * (1 - expand)
            content
                .frame(width: full.width, height: full.height)
                .scaleEffect(scale)
                .offset(x: frame.midX - full.midX, y: frame.midY - full.midY)
                .mask(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                )
        }
    }
}
