import SwiftUI
import UIKit

struct AsciiBackground: UIViewRepresentable {
    let color: String
    let isMoving: Bool

    func makeUIView(context: Context) -> AsciiBackdropView {
        AsciiBackdropView()
    }

    func updateUIView(_ view: AsciiBackdropView, context: Context) {
        view.update(color: color.uppercased(), isMoving: isMoving && !context.environment.accessibilityReduceMotion)
    }
}

final class AsciiBackdropView: UIView {
    private static let tokens = Tokens.shared.background
    private static let angle = CGFloat(tokens.angleDegrees) * .pi / 180
    private static let driftKey = "drift"

    private static let art: String = {
        guard let url = Bundle.main.url(forResource: "background", withExtension: "txt"), let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text.trimmingCharacters(in: .newlines)
    }()

    private let pattern = UIView()
    private var color: String?
    private var isMoving = false
    private var tileSize: CGSize = .zero
    private var laidOutSize: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        clipsToBounds = true
        alpha = CGFloat(Self.tokens.opacity)
        accessibilityElementsHidden = true
        addSubview(pattern)
        NotificationCenter.default.addObserver(self, selector: #selector(restartDrift), name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func update(color: String, isMoving: Bool) {
        if color != self.color {
            self.color = color
            renderTile(UIColor(hex: color))
            laidOutSize = .zero
            setNeedsLayout()
        }
        if isMoving != self.isMoving {
            self.isMoving = isMoving
            restartDrift()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard tileSize.width > 0, bounds.size != laidOutSize else { return }
        laidOutSize = bounds.size
        let reach = hypot(bounds.width, bounds.height) + max(tileSize.width, tileSize.height) * 2
        pattern.transform = .identity
        pattern.bounds = CGRect(x: 0, y: 0, width: reach, height: reach)
        pattern.center = CGPoint(x: bounds.midX, y: bounds.midY)
        pattern.transform = CGAffineTransform(rotationAngle: Self.angle)
        restartDrift()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        restartDrift()
    }

    private func renderTile(_ color: UIColor) {
        guard !Self.art.isEmpty else { return }
        let gap = CGFloat(Self.tokens.gap)
        let attributes: [NSAttributedString.Key: Any] = [.font: Typography.monoFont(CGFloat(Self.tokens.fontSize)), .foregroundColor: color]
        let measured = (Self.art as NSString).size(withAttributes: attributes)
        tileSize = CGSize(width: ceil(measured.width + gap), height: ceil(measured.height + gap))
        let image = UIGraphicsImageRenderer(size: tileSize).image { _ in
            (Self.art as NSString).draw(at: CGPoint(x: gap / 2, y: gap / 2), withAttributes: attributes)
        }
        pattern.backgroundColor = UIColor(patternImage: image)
    }

    @objc private func restartDrift() {
        pattern.layer.removeAnimation(forKey: Self.driftKey)
        guard isMoving, window != nil, tileSize.width > 0, Self.tokens.speed > 0 else { return }
        let drift = CABasicAnimation(keyPath: "position")
        drift.isAdditive = true
        drift.fromValue = NSValue(cgPoint: .zero)
        drift.toValue = NSValue(cgPoint: CGPoint(x: tileSize.width * cos(Self.angle), y: tileSize.width * sin(Self.angle)))
        drift.duration = Double(tileSize.width) / Self.tokens.speed
        drift.repeatCount = .infinity
        drift.isRemovedOnCompletion = false
        pattern.layer.add(drift, forKey: Self.driftKey)
    }
}
