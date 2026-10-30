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
    static let navigationPopMilliseconds = durations.navigationPop
    static let navigationSpreadMilliseconds = durations.navigationSpread
    static let navigationSpreadDelayMilliseconds = durations.navigationSpreadDelay
    static let navigationElementMilliseconds = durations.navigationElement
    static let navigationSwitchMilliseconds = durations.navigationSwitch
    static let navigationLeaveElementMilliseconds = durations.navigationLeaveElement
    static let navigationLeaveSpreadMilliseconds = durations.navigationLeaveSpread
    static let navigationLeavePopMilliseconds = durations.navigationLeavePop
    static let keyboardMilliseconds = durations.keyboard
    static let typeMilliseconds = durations.type
    static let undoTapMilliseconds = durations.undoTap
    static let navigationEdgeHideMilliseconds = durations.navEdgeHide

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

    static func keyboard(_ milliseconds: Int = keyboardMilliseconds) -> Animation {
        animation(curves.keyboard, milliseconds, 0)
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
        insertion: AnyTransition.modifier(active: RotatePop(isShown: false), identity: RotatePop(isShown: true)).animation(Motion.powerTwoOut(Motion.navigationSwitchMilliseconds, delay: Motion.navigationSwitchMilliseconds / 2)),
        removal: AnyTransition.modifier(active: RotatePop(isShown: false), identity: RotatePop(isShown: true)).animation(Motion.powerTwoIn(Motion.navigationSwitchMilliseconds))
    )

    static let popTogether: AnyTransition = .asymmetric(
        insertion: AnyTransition.modifier(active: RotatePop(isShown: false), identity: RotatePop(isShown: true)).animation(Motion.powerTwoOut(Motion.stateMilliseconds)),
        removal: AnyTransition.modifier(active: RotatePop(isShown: false), identity: RotatePop(isShown: true)).animation(Motion.powerTwoIn(Motion.stateMilliseconds))
    )

    static let folder: AnyTransition = .asymmetric(
        insertion: AnyTransition.opacity.combined(with: .scale(scale: Motion.scales.folderEnter)).animation(Motion.powerTwoOut(Motion.sectionEnterMilliseconds, delay: Motion.sectionEnterDelayMilliseconds)),
        removal: AnyTransition.opacity.animation(Motion.powerTwoIn(Motion.sectionLeaveMilliseconds))
    )

    static let fromTopEdge: AnyTransition = .asymmetric(
        insertion: AnyTransition.move(edge: .top).animation(Motion.powerTwoOut(Motion.sheetDropMilliseconds)),
        removal: AnyTransition.move(edge: .top).animation(Motion.powerTwoIn(Motion.sheetDropMilliseconds))
    )

    static let elementLeave: AnyTransition = .asymmetric(
        insertion: .identity,
        removal: AnyTransition.modifier(active: RotatePop(isShown: false), identity: RotatePop(isShown: true)).animation(Motion.powerTwoIn(Motion.navigationSwitchMilliseconds))
    )

    static let groupLeave: AnyTransition = .asymmetric(
        insertion: .identity,
        removal: AnyTransition.opacity.animation(Motion.powerTwoIn(Motion.pressMilliseconds))
    )

    static let sliderEnter: AnyTransition = .asymmetric(
        insertion: AnyTransition.scale(scale: CGFloat(Motion.scales.sliderEnter)).combined(with: .opacity).animation(Motion.powerTwoOut(Motion.overlayLeaveMilliseconds, delay: Motion.pressMilliseconds)),
        removal: AnyTransition.opacity.animation(Motion.powerTwoIn(Motion.pressMilliseconds))
    )

    static let flight: AnyTransition = .asymmetric(
        insertion: .identity,
        removal: AnyTransition.opacity.animation(Motion.powerTwoIn(Motion.sectionLeaveMilliseconds))
    )

    static let returning: AnyTransition = .asymmetric(
        insertion: .identity,
        removal: AnyTransition.opacity.animation(Motion.powerTwoIn(Motion.sectionLeaveMilliseconds))
    )

    static let section: AnyTransition = .asymmetric(
        insertion: AnyTransition.opacity.combined(with: .scale(scale: 0.96)).animation(Motion.powerTwoOut(Motion.sectionEnterMilliseconds, delay: Motion.sectionEnterDelayMilliseconds)),
        removal: AnyTransition.opacity.animation(Motion.powerTwoIn(Motion.sectionLeaveMilliseconds))
    )

    static let overlay: AnyTransition = .asymmetric(
        insertion: AnyTransition.opacity.combined(with: .scale(scale: 0.94)).combined(with: .offset(y: 24)).animation(Motion.powerTwoOut(Motion.overlayEnterMilliseconds)),
        removal: AnyTransition.opacity.combined(with: .scale(scale: 0.96)).animation(Motion.powerTwoIn(Motion.overlayLeaveMilliseconds))
    )
}

struct RotatePop: ViewModifier {
    let isShown: Bool

    static let turn = Angle.degrees(-90)
    static let perspective: CGFloat = 0.5

    func body(content: Content) -> some View {
        content
            .scaleEffect(isShown ? 1 : 0.001)
            .rotation3DEffect(isShown ? .zero : Self.turn, axis: (x: 0, y: 1, z: 0), perspective: Self.perspective)
            .opacity(isShown ? 1 : 0)
    }
}

private struct ElementRevealKey: EnvironmentKey {
    static let defaultValue: Bool? = nil
}

extension EnvironmentValues {
    var isElementRevealed: Bool? {
        get { self[ElementRevealKey.self] }
        set { self[ElementRevealKey.self] = newValue }
    }
}

struct ElementReveal: ViewModifier {
    @Environment(\.isElementRevealed) private var isRevealed
    @State private var hasAppeared = false
    @State private var isSwitchedIn = false
    @State private var enterDelay = Int.random(in: 0...Motion.navigationElementMilliseconds / 2)
    @State private var leaveDelay = Int.random(in: 0...Motion.navigationLeaveElementMilliseconds / 2)

    private var isShown: Bool { (isRevealed ?? true) && hasAppeared }

    private var enterAnimation: Animation {
        guard isSwitchedIn else {
            return Motion.powerTwoOut(Motion.navigationElementMilliseconds, delay: enterDelay)
        }
        let spread = enterDelay * Motion.navigationSwitchMilliseconds / 2 / max(1, Motion.navigationElementMilliseconds)
        return Motion.powerTwoOut(Motion.navigationSwitchMilliseconds, delay: Motion.navigationSwitchMilliseconds / 2 + spread)
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if isRevealed == nil {
            content
        } else {
            revealed(content)
        }
    }

    private func revealed(_ content: Content) -> some View {
        content
            .modifier(RotatePop(isShown: isShown))
            .animation(
                isShown ? enterAnimation : Motion.powerTwoIn(Motion.navigationLeaveElementMilliseconds, delay: leaveDelay),
                value: isShown
            )
            .onAppear {
                isSwitchedIn = isRevealed == true
                hasAppeared = true
            }
            .onChange(of: isRevealed) { _, revealed in
                if revealed == false {
                    isSwitchedIn = false
                }
            }
    }
}

extension View {
    func revealedElement() -> some View {
        modifier(ElementReveal())
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

    func body(content: Content) -> some View {
        content
            .modifier(RotatePop(isShown: isShown))
            .animation(
                isShown ? Motion.powerTwoOut(Motion.stateMilliseconds, delay: order * Motion.chromeStaggerMilliseconds) : Motion.powerTwoIn(Motion.navigationLeaveElementMilliseconds),
                value: isShown
            )
    }
}

@MainActor
final class PillMotion: ObservableObject {
    @Published private(set) var shellScale: CGFloat = 0
    @Published private(set) var shellSpread: CGFloat = 0
    @Published private(set) var areElementsShown = false
    @Published private(set) var isPresent = false
    private var step = 0

    private static var enterMilliseconds: Int {
        max(Motion.navigationPopMilliseconds, Motion.navigationSpreadDelayMilliseconds + Motion.navigationSpreadMilliseconds / 2)
    }

    private func after(_ milliseconds: Int, _ change: @escaping () -> Void) {
        let current = step
        DispatchQueue.main.asyncAfter(deadline: .now() + Motion.seconds(milliseconds)) { [weak self] in
            guard let self, current == self.step else { return }
            change()
        }
    }

    func enter() {
        step += 1
        let isMidLeave = isPresent && shellScale > 0
        if !isMidLeave {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                shellScale = 0
                shellSpread = 0
                areElementsShown = false
                isPresent = true
            }
        }
        after(0) { [weak self] in
            withAnimation(Motion.powerTwoOut(Motion.navigationPopMilliseconds)) {
                self?.shellScale = 1
            }
            withAnimation(Motion.powerThreeInOut(Motion.navigationSpreadMilliseconds, delay: isMidLeave ? 0 : Motion.navigationSpreadDelayMilliseconds)) {
                self?.shellSpread = 1
            }
        }
        after(isMidLeave ? Motion.navigationSpreadMilliseconds / 2 : Self.enterMilliseconds) { [weak self] in
            self?.areElementsShown = true
        }
    }

    func leave(keepsShape: Bool = false, then finish: @escaping () -> Void = {}) {
        guard isPresent else { return }
        step += 1
        areElementsShown = false
        let elementsGone = Motion.navigationLeaveElementMilliseconds
        let narrowed = elementsGone + Motion.navigationLeaveSpreadMilliseconds * 3 / 4
        let gone = narrowed + Motion.navigationLeavePopMilliseconds
        if keepsShape {
            after(elementsGone) { [weak self] in
                withAnimation(Motion.powerTwoIn(gone - elementsGone)) {
                    self?.shellScale = 0
                }
            }
            after(gone) { [weak self] in
                self?.isPresent = false
                finish()
            }
            return
        }
        after(elementsGone) { [weak self] in
            withAnimation(Motion.powerThreeInOut(Motion.navigationLeaveSpreadMilliseconds)) {
                self?.shellSpread = 0
            }
        }
        after(narrowed) { [weak self] in
            withAnimation(Motion.powerTwoIn(Motion.navigationLeavePopMilliseconds)) {
                self?.shellScale = 0
            }
        }
        after(gone) { [weak self] in
            self?.isPresent = false
            finish()
        }
    }
}

struct PillShell: View {
    let scale: CGFloat
    let spread: CGFloat
    let isWide: Bool
    var stroke: Color = Palette.border

    var body: some View {
        GeometryReader { proxy in
            let full = proxy.size
            let thickness = isWide ? full.height : full.width
            let along = thickness + ((isWide ? full.width : full.height) - thickness) * spread
            Capsule()
                .fill(Palette.panelSolid)
                .overlay(Capsule().stroke(stroke, lineWidth: 1))
                .frame(width: isWide ? along : thickness, height: isWide ? thickness : along)
                .scaleEffect(scale)
                .shadow(color: .black.opacity(0.45), radius: 16, y: 12)
                .frame(width: full.width, height: full.height)
        }
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
