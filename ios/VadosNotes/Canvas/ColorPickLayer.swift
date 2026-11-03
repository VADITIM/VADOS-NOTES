import SwiftUI
import UIKit

extension InkCanvasView {
    func sampleColor(atWindowPoint point: CGPoint) -> String? {
        let local = convert(point, from: nil)
        guard bounds.contains(local) else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        let didRender = pixel.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.translateBy(x: -local.x, y: -local.y)
            layer.render(in: context)
            return true
        }
        guard didRender else { return nil }
        let ground = UIColor(Palette.ground)
        var groundRed: CGFloat = 0
        var groundGreen: CGFloat = 0
        var groundBlue: CGFloat = 0
        var groundAlpha: CGFloat = 0
        ground.getRed(&groundRed, green: &groundGreen, blue: &groundBlue, alpha: &groundAlpha)
        let alpha = CGFloat(pixel[3]) / 255
        let blend = { (premultiplied: UInt8, under: CGFloat) -> Int in
            Int(((CGFloat(premultiplied) / 255 + under * (1 - alpha)) * 255).rounded())
        }
        return String(format: "#%02X%02X%02X", min(255, blend(pixel[0], groundRed)), min(255, blend(pixel[1], groundGreen)), min(255, blend(pixel[2], groundBlue)))
    }
}

@MainActor
final class CanvasSampler {
    static let shared = CanvasSampler()
    weak var canvas: InkCanvasView?

    func sample(_ point: CGPoint) -> String? {
        canvas?.sampleColor(atWindowPoint: point)
    }
}

struct ColorPickLayer: View {
    let onPick: (String) -> Void
    let onCancel: () -> Void

    @State private var point: CGPoint?
    @State private var color: String?
    @State private var isTouch = true
    @State private var isHintShown = false

    private static let loupeLift: CGFloat = 64
    private static let loupeDiameter: CGFloat = 56

    var body: some View {
        GeometryReader { proxy in
            let origin = proxy.frame(in: .global).origin
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .global)
                            .onChanged { value in
                                isTouch = true
                                update(value.location)
                            }
                            .onEnded { value in
                                update(value.location)
                                if let color {
                                    Haptics.landed()
                                    onPick(color)
                                } else {
                                    point = nil
                                }
                            }
                    )
                    .onContinuousHover(coordinateSpace: .global) { phase in
                        if case .active(let location) = phase {
                            isTouch = false
                            update(location)
                        }
                    }
                if let point {
                    loupe
                        .position(x: point.x - origin.x, y: point.y - origin.y - (isTouch ? Self.loupeLift : 0))
                        .allowsHitTesting(false)
                        .transition(.popTogether)
                }
                hint
                    .frame(maxWidth: .infinity)
                    .padding(.top, 72)
                    .modifier(RotatePop(isShown: isHintShown))
                    .animation(Motion.powerTwoOut(Motion.stateMilliseconds), value: isHintShown)
            }
        }
        .ignoresSafeArea()
        .onAppear { isHintShown = true }
    }

    private var loupe: some View {
        VStack(spacing: 8) {
            Circle()
                .strokeBorder(color.map { Color(hex: $0) } ?? Color.clear, lineWidth: 8)
                .overlay(Circle().stroke(Color.white.opacity(0.85), lineWidth: 1))
                .overlay(Circle().stroke(Color.black.opacity(0.6), lineWidth: 1).padding(-1))
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.9), lineWidth: 1)
                        .frame(width: 6, height: 6)
                )
                .frame(width: Self.loupeDiameter, height: Self.loupeDiameter)
                .shadow(color: .black.opacity(0.5), radius: 14, y: 12)
            Text(color ?? "—")
                .font(Typography.mono(10))
                .tracking(1)
                .foregroundColor(color.map { Palette.isLight($0) ? Palette.ground : Palette.textBright } ?? Palette.textBright)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Capsule().fill(color.map { Color(hex: $0) } ?? Palette.sunken))
                .overlay(Capsule().stroke(Palette.borderControl, lineWidth: 1))
                .fixedSize()
        }
        .offset(y: 15)
    }

    private var hint: some View {
        HStack(spacing: 10) {
            GlyphView(name: "eyedropper", color: Palette.accent, size: 16)
            MicroLabel(text: "Pick a colour from the canvas")
            Button(action: onCancel) {
                GlyphView(name: "close", color: Palette.textBody, size: 14)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Palette.sunken))
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel("Cancel")
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .frame(height: 40)
        .background(Capsule().fill(Palette.panelSolid))
        .overlay(Capsule().stroke(Palette.borderControl, lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 16, y: 12)
        .fixedSize()
    }

    private func update(_ location: CGPoint) {
        withAnimation(point == nil ? Motion.powerTwoOut(Motion.stateMilliseconds) : nil) {
            point = location
        }
        color = CanvasSampler.shared.sample(location)
    }
}
