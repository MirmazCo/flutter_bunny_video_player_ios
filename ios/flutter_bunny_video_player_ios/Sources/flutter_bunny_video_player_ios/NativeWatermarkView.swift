import UIKit

/// Floating user-id watermark that drifts across the player.
///
/// Visuals match the Flutter `VideoPlayerWaterMark` used on Mirmaz lessons
/// (red, ~60% opacity, relocates every few seconds) so the SwiftUI fullscreen
/// cover looks the same as the inline overlay it replaces.
final class NativeWatermarkView: UIView {
    static let viewTag = 918_273_645

    private let textLabel = UILabel()
    private var moveTimer: Timer?
    private var currentAnimator: UIViewPropertyAnimator?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        tag = Self.viewTag
        isUserInteractionEnabled = false
        backgroundColor = .clear

        textLabel.textColor = UIColor.red.withAlphaComponent(0.6)
        textLabel.font = .systemFont(ofSize: 16)
        textLabel.layer.shadowColor = UIColor.black.cgColor
        textLabel.layer.shadowOffset = CGSize(width: 0.5, height: 0.5)
        textLabel.layer.shadowRadius = 1.5
        textLabel.layer.shadowOpacity = 0.5
        textLabel.sizeToFit()

        addSubview(textLabel)
        textLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            textLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            textLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func setText(_ text: String) {
        textLabel.text = text
        textLabel.sizeToFit()
    }

    func startAnimation() {
        moveTimer?.invalidate()
        let timer = Timer(timeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.moveRandomly()
        }
        RunLoop.main.add(timer, forMode: .common)
        moveTimer = timer
        // First hop soon after attach so the id isn't stuck dead-centre.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.moveRandomly()
        }
    }

    func stopAnimation() {
        moveTimer?.invalidate()
        moveTimer = nil
        currentAnimator?.stopAnimation(true)
        currentAnimator = nil
    }

    private func moveRandomly() {
        let parentWidth = bounds.width
        let parentHeight = bounds.height
        guard parentWidth > 0, parentHeight > 0 else { return }

        let textWidth = textLabel.intrinsicContentSize.width
        let textHeight = textLabel.intrinsicContentSize.height
        let maxTranslateX = (parentWidth - textWidth) / 2
        let maxTranslateY = (parentHeight - textHeight) / 2
        guard maxTranslateX > 0, maxTranslateY > 0 else { return }

        let randomX = CGFloat.random(in: -1...1) * maxTranslateX
        let randomY = CGFloat.random(in: -1...1) * maxTranslateY

        currentAnimator?.stopAnimation(true)
        currentAnimator = UIViewPropertyAnimator(duration: 1.0, curve: .easeInOut) { [weak self] in
            self?.textLabel.transform = CGAffineTransform(translationX: randomX, y: randomY)
        }
        currentAnimator?.startAnimation()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            startAnimation()
        } else {
            stopAnimation()
        }
    }
}
