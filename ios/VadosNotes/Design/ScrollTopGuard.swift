import SwiftUI
import UIKit

struct ScrollTopGuard: UIViewRepresentable {
    func makeUIView(context: Context) -> GuardView {
        GuardView()
    }

    func updateUIView(_ view: GuardView, context: Context) {
        view.releaseScrollView()
    }

    final class GuardView: UIView {
        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            backgroundColor = .clear
        }

        required init?(coder: NSCoder) {
            fatalError("GuardView is created in code")
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            releaseScrollView()
            DispatchQueue.main.async { [weak self] in
                self?.releaseScrollView()
            }
        }

        func releaseScrollView() {
            var current = superview
            while let view = current {
                if let scrollView = view as? UIScrollView {
                    scrollView.scrollsToTop = false
                    return
                }
                current = view.superview
            }
        }
    }
}

extension View {
    func scrollsToTopDisabled() -> some View {
        background(ScrollTopGuard().allowsHitTesting(false))
    }
}
