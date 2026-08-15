import UIKit
import AVFoundation

/// A `UITextField` whose only job is to lend its secure content view.
///
/// UIKit renders the content view of a secure text field through a path the
/// capture pipeline is not allowed to read: it reaches the display, but it is
/// omitted from screenshots, screen recordings and AirPlay mirroring. Parking
/// the video under that view is the only mechanism iOS offers — there is no
/// `FLAG_SECURE` equivalent — and, unlike blanking the picture, it costs the
/// person actually watching nothing at all.
///
/// This field never participates in touch handling: it is a container, dropped
/// into the SDK's own view tree, and every hit test falls straight through it.
final class SecureCanvasField: UITextField {
    override var canBecomeFirstResponder: Bool { false }

    override func becomeFirstResponder() -> Bool { false }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool { false }

    override func caretRect(for position: UITextPosition) -> CGRect { .zero }

    /// UIKit sizes the secure canvas to the *text* area, which is a few points
    /// tall and inset — useless as a video host. Forcing it to the field's
    /// bounds on every pass keeps the mirror in exactly the rectangle the
    /// `AVPlayerLayer` occupied.
    override func layoutSubviews() {
        super.layoutSubviews()
        for canvas in subviews {
            canvas.frame = bounds
            canvas.clipsToBounds = false
        }
    }

    /// Never swallow a tap meant for the player controls.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        return nil
    }
}

/// Provides the capture-excluded container the video mirror draws into.
///
/// ## What this deliberately does *not* do
///
/// An earlier version also re-parented the fullscreen cover's whole view tree
/// under a secure field, to keep the SDK's controls out of captures too. That
/// is gone, for two reasons:
///
///  * It never protected the video. `AVPlayerLayer` output is composited
///    through the media pipeline, which the capture path samples independently
///    of the layer tree the player nominally hangs in — so no amount of
///    re-parenting hides it. That is what `SecureVideoMirror` exists for.
///  * Moving a live SwiftUI hierarchy breaks hit-testing. Views ended up inside
///    a container UIKit does not expect to host them, and the SDK's fullscreen
///    controls became hard to press — real damage, in exchange for nothing.
///
/// What is left is additive only: a passthrough container dropped inside the
/// SDK's video surface. Nothing is moved, nothing is re-parented, and touch
/// handling is untouched.
enum NativeScreenshotShield {
    /// A capture-excluded view filling [host], creating it on first use.
    ///
    /// [host] is the view whose layer carries the `AVPlayerLayer`, so a subview
    /// of it lands in exactly the right slot: above the video, below the SDK's
    /// controls.
    static func secureCanvas(in host: UIView) -> UIView? {
        let field = existingField(in: host) ?? install(in: host)

        // Re-assert on every call: the SDK resizes its surface on rotation and
        // on the inline ↔ fullscreen swap, and a stale frame would leave the
        // mirror drawing at the wrong size.
        if field.frame != host.bounds {
            field.frame = host.bounds
            field.setNeedsLayout()
            field.layoutIfNeeded()
        }
        // A field that lost its secure flag protects nothing.
        if !field.isSecureTextEntry { field.isSecureTextEntry = true }

        if let canvas = findSecureCanvas(in: field) { return canvas }

        field.setNeedsLayout()
        field.layoutIfNeeded()
        return findSecureCanvas(in: field)
    }

    /// Names UIKit has given the secure content view of a `UITextField`.
    ///
    /// It is the *only* view in the field whose subtree the capture pipeline
    /// skips. Everything else in there is an ordinary view.
    private static let secureCanvasClassNames: Set<String> = [
        "_UITextLayoutCanvasView",
        "_UITextFieldCanvasView",
        "_UITextFieldContentView",
    ]

    /// Locates the secure content view inside [field].
    ///
    /// Deliberately matched by class name and searched over the whole subtree,
    /// rather than taken as `field.subviews.first`.
    ///
    /// That shortcut is the standard recipe and it is a silent trap: it assumes
    /// UIKit's private view layout inside `UITextField`, which changes between
    /// iOS releases. If the first subview is not the secure canvas — because it
    /// moved deeper, or a new wrapper was introduced — content added to it is
    /// **not** protected, while looking completely correct on screen. Nothing
    /// about the picture would tell you; only the screenshot differs.
    ///
    /// So an unrecognised layout is reported loudly instead of assumed to work.
    private static func findSecureCanvas(in field: UITextField) -> UIView? {
        if let match = firstSecureCanvas(under: field) { return match }
        guard !field.subviews.isEmpty else { return nil }

        NSLog(
            "🛡️ [BunnyPlayer] SECURE CANVAS NOT FOUND — UITextField subtree is %@. "
                + "The video CANNOT be protected on this iOS version.",
            describeTree(field)
        )
        return nil
    }

    private static func firstSecureCanvas(under view: UIView) -> UIView? {
        for subview in view.subviews {
            if secureCanvasClassNames.contains(String(describing: type(of: subview))) {
                return subview
            }
            if let found = firstSecureCanvas(under: subview) { return found }
        }
        return nil
    }

    private static func describeTree(_ view: UIView, depth: Int = 0) -> String {
        let name = String(describing: type(of: view))
        if depth > 3 { return name }
        let children = view.subviews
            .map { describeTree($0, depth: depth + 1) }
            .joined(separator: ", ")
        return children.isEmpty ? name : "\(name)[\(children)]"
    }

    /// Removes the container from [host], if one was installed.
    static func removeSecureCanvas(from host: UIView) {
        existingField(in: host)?.removeFromSuperview()
    }

    /// The view whose layer hosts the `AVPlayerLayer` somewhere under [root].
    ///
    /// Walks *up* from the player layer to the nearest layer that backs a view,
    /// rather than looking only at the immediate superlayer.
    ///
    /// That shortcut was a real bug: the zoom feature splices a plain `CALayer`
    /// between the player layer and its host view's layer, and a plain layer has
    /// no view delegate. From the moment the first layout pass installed that
    /// container, this returned nil, the mirror silently never started, and the
    /// video stayed capturable — in fullscreen especially, where the zoom
    /// container is rebuilt on every presentation.
    static func videoSurfaceView(in root: UIView) -> UIView? {
        guard let playerLayer = findPlayerLayer(in: root) else { return nil }
        var node: CALayer? = playerLayer
        while let current = node {
            if let view = current.delegate as? UIView { return view }
            node = current.superlayer
        }
        return nil
    }

    /// True when [layer] sits under a secure canvas installed in [host].
    static func isSecured(_ layer: CALayer, in host: UIView) -> Bool {
        guard let field = existingField(in: host),
              let canvasLayer = findSecureCanvas(in: field)?.layer else {
            return false
        }
        var node: CALayer? = layer
        while let current = node {
            if current === canvasLayer { return true }
            node = current.superlayer
        }
        return false
    }

    // MARK: - Install

    private static func existingField(in host: UIView) -> SecureCanvasField? {
        return host.subviews.compactMap { $0 as? SecureCanvasField }.first
    }

    private static func install(in host: UIView) -> SecureCanvasField {
        let field = SecureCanvasField()
        field.isSecureTextEntry = true
        // Belt and braces with `hitTest`: this container must be invisible to
        // touch handling from every angle.
        field.isUserInteractionEnabled = false
        field.backgroundColor = .clear
        field.textColor = .clear
        field.tintColor = .clear
        field.borderStyle = .none
        field.clipsToBounds = false
        field.translatesAutoresizingMaskIntoConstraints = true
        field.frame = host.bounds
        field.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        host.addSubview(field)
        field.setNeedsLayout()
        field.layoutIfNeeded()

        // Re-arm: UIKit builds the secure content view lazily, and on some
        // releases only after the flag is set on a field that is already in a
        // hierarchy. Toggling it here is free — nothing has been placed inside
        // yet, so there is nothing to orphan.
        if findSecureCanvas(in: field) == nil {
            field.isSecureTextEntry = false
            field.isSecureTextEntry = true
            field.setNeedsLayout()
            field.layoutIfNeeded()
        }

        if let canvas = findSecureCanvas(in: field) {
            NSLog(
                "🛡️ [BunnyPlayer] secure container installed — canvas is %@",
                String(describing: type(of: canvas))
            )
        }
        return field
    }

    // MARK: - Lookup

    private static func findPlayerLayer(in view: UIView) -> AVPlayerLayer? {
        if let found = findPlayerLayer(in: view.layer) { return found }
        for child in view.subviews {
            if let found = findPlayerLayer(in: child) { return found }
        }
        return nil
    }

    private static func findPlayerLayer(in layer: CALayer) -> AVPlayerLayer? {
        if let player = layer as? AVPlayerLayer { return player }
        for sub in layer.sublayers ?? [] {
            if let found = findPlayerLayer(in: sub) { return found }
        }
        return nil
    }
}
