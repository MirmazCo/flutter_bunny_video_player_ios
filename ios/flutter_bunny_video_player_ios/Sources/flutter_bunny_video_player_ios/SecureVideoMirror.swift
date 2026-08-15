import UIKit
import AVFoundation
import VideoToolbox

/// Paints the video with CoreAnimation instead of `AVPlayerLayer`, so the
/// secure canvas can actually keep it out of screenshots.
///
/// ## Why this exists
///
/// A secure `UITextField`'s content view excludes its subtree from every system
/// capture — but only for content the *render server* composites, which is
/// where CoreAnimation content lives. `AVPlayerLayer` is not that: video is
/// handed to the display through the media pipeline, and the capture path
/// samples it independently of the layer tree it nominally hangs in. Parenting
/// the player under a secure canvas therefore changes nothing at all — the
/// screenshot still comes out with the video in it, which is exactly what was
/// observed, and almost certainly why blanking the picture was reached for as a
/// fallback in the first place.
///
/// So the video is taken out of that pipeline entirely:
///
///  * `AVPlayerItemVideoOutput` pulls decoded frames straight off the item, and
///    `suppressesPlayerRendering` tells AVFoundation to stop drawing to *any*
///    player layer for that item — there is no video surface left to capture,
///    even if the SDK un-hides its own layer.
///  * Each frame becomes a `CGImage` assigned to a plain `CALayer.contents`,
///    parked next to the (now dark) `AVPlayerLayer`. That is ordinary
///    CoreAnimation content, so the secure canvas above it does exclude it.
///
/// The viewer sees the video exactly as before, at full frame rate, with no
/// blanking and no interruption. A screenshot comes out without it.
///
/// ## Never leave a black player
///
/// The mirror does not take the picture away from `AVPlayerLayer` on faith. It
/// runs alongside it first, and only suppresses player rendering once it has
/// actually put [framesBeforeTakeover] frames on screen. Anything that stops it
/// working — a FairPlay item that refuses to hand pixels to an output, a pixel
/// format that will not convert — leaves normal playback untouched instead of
/// blanking the video, and the mirror stands down for good.
///
/// This ordering matters: an earlier revision hid the player *first* and
/// assigned each frame's `IOSurface` to `layer.contents`, which iOS silently
/// does not render. Frames were "delivered" every tick, so no stall was ever
/// detected, and fullscreen went completely black.
final class SecureVideoMirror {
    /// The view the frames are painted into, added as a **subview** of the
    /// secure canvas.
    ///
    /// Deliberately a view and not a bare `CALayer` spliced into the canvas's
    /// layer. UIKit's exclusion is documented (as far as it is documented at
    /// all) in terms of the secure field's content *view hierarchy*, and every
    /// implementation known to work adds subviews to it. A raw sublayer sits in
    /// the right layer tree but has never been a shape UIKit promises anything
    /// about — and getting that wrong looks identical to working, because the
    /// picture is correct on screen either way and only the screenshot differs.
    private let mirrorView = UIView()

    /// The layer the frames actually land on.
    var layer: CALayer { mirrorView.layer }

    private weak var player: AVPlayer?
    private weak var sourceLayer: AVPlayerLayer?
    private weak var observedItem: AVPlayerItem?

    /// The capture-excluded view the frames are drawn inside. Owned by
    /// `NativeScreenshotShield` and parked in the SDK's video surface, so the
    /// mirror lands in the same slot the `AVPlayerLayer` occupied: above the
    /// video, below the controls.
    private weak var secureCanvas: UIView?

    /// The zoom the host is applying to the real player, mirrored here because
    /// the mirror lives outside the zoom container.
    private var zoomTransform = CATransform3DIdentity
    private var output: AVPlayerItemVideoOutput?
    private var displayLink: CADisplayLink?

    /// How many frames must be visibly on screen before the real player is
    /// allowed to go dark. Small enough to be imperceptible, large enough that
    /// a mirror which cannot draw never gets the chance to blank the video.
    private let framesBeforeTakeover = 5

    /// Consecutive conversion failures tolerated before standing down.
    private let conversionFailureLimit = 30

    private var framesDelivered = 0
    private var conversionFailures = 0
    private var hasTakenOver = false
    private var startedAt: CFTimeInterval = 0
    private var abandoned = false

    var isRunning: Bool { displayLink != nil }

    /// Starts mirroring [player] in place of [source], or re-targets an
    /// existing mirror. Idempotent — safe to call from a layout pass or a
    /// watchdog tick.
    ///
    /// Returns `true` while the mirror owns the picture.
    @discardableResult
    func attach(player: AVPlayer, source: AVPlayerLayer, canvas: UIView) -> Bool {
        if abandoned { return false }

        // Already mirroring the same player + item: just keep the geometry
        // honest and let the display link do its job.
        if isRunning,
           sourceLayer === source,
           secureCanvas === canvas,
           self.player === player,
           observedItem === player.currentItem {
            syncPlacement()
            return true
        }

        stop(restoringSource: true)
        guard let item = player.currentItem else { return false }
        secureCanvas = canvas

        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        let videoOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: attributes)
        // Deliberately *not* suppressing player rendering yet — the real player
        // keeps the picture until the mirror has proven it can draw. See
        // `takeOverIfReady`.
        videoOutput.suppressesPlayerRendering = false
        item.add(videoOutput)

        self.player = player
        self.sourceLayer = source
        self.observedItem = item
        self.output = videoOutput

        layer.masksToBounds = true
        // Transparent, not black: while the mirror is still proving itself it
        // sits directly on top of the live player, and an opaque background
        // would black the video out for those few frames.
        layer.backgroundColor = UIColor.clear.cgColor
        syncPlacement()

        let link = CADisplayLink(target: self, selector: #selector(step(_:)))
        // Platform views can sit outside the default run-loop mode.
        link.add(to: .main, forMode: .common)
        displayLink = link

        framesDelivered = 0
        conversionFailures = 0
        hasTakenOver = false
        startedAt = CACurrentMediaTime()
        NSLog("🛡️ [BunnyPlayer] secure video mirror started (player still rendering)")
        return true
    }

    /// Keeps the mirror where the video would have been.
    ///
    /// Called from the owner's layout pass as well as every frame: the SDK
    /// rewrites `playerLayer.frame` constantly, and the zoom container is
    /// re-installed whenever the SwiftUI hierarchy is rebuilt.
    func syncPlacement() {
        guard let source = sourceLayer, let canvas = secureCanvas else { return }

        if mirrorView.superview !== canvas {
            mirrorView.removeFromSuperview()
            mirrorView.isUserInteractionEnabled = false
            mirrorView.translatesAutoresizingMaskIntoConstraints = true
            // No autoresizing: geometry is written explicitly below, because a
            // resize would go through `frame` — see the warning there.
            mirrorView.autoresizingMask = []
            canvas.addSubview(mirrorView)
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // The canvas is pinned to the surface view, which is also what the SDK
        // sizes its player layer to, so filling the canvas reproduces the video
        // rect exactly — without depending on the SDK's layer geometry, which it
        // rewrites on every layout pass.
        //
        // Written as bounds + center, never `frame`. `frame` is *derived* from
        // bounds, position and transform, so assigning it to a zoomed view
        // solves back for a smaller bounds — at 2× it halves them, and the
        // scaled result covers exactly the rectangle it started from. Since this
        // runs on every frame, a pinch was being applied and then immediately
        // cancelled, which is why zoom stopped working. (The SDK's own player
        // layer has the identical hazard; the zoom container exists to keep our
        // transform off the layer the SDK assigns `frame` to.)
        let bounds = canvas.bounds
        if mirrorView.bounds.size != bounds.size {
            mirrorView.bounds = CGRect(origin: .zero, size: bounds.size)
        }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        if mirrorView.center != center {
            mirrorView.center = center
        }
        layer.transform = zoomTransform
        // Match how the SDK letterboxes, or the mirror would crop differently
        // from the player it replaces.
        switch source.videoGravity {
        case .resizeAspectFill: layer.contentsGravity = .resizeAspectFill
        case .resize: layer.contentsGravity = .resize
        default: layer.contentsGravity = .resizeAspect
        }
        CATransaction.commit()
    }

    /// Mirrors the host's zoom onto the drawn frames.
    ///
    /// The real player is zoomed by a container layer this mirror deliberately
    /// does not live in — being outside the SDK's layer tree is what keeps the
    /// placement stable — so the same transform is applied here by hand.
    func applyZoom(_ transform: CATransform3D, animatedFrom previous: CATransform3D? = nil) {
        zoomTransform = transform
        guard mirrorView.superview != nil else { return }
        if let previous = previous {
            let animation = CABasicAnimation(keyPath: "transform")
            animation.fromValue = previous
            animation.toValue = transform
            animation.duration = 0.25
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(animation, forKey: "mirrorZoom")
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = transform
        CATransaction.commit()
    }

    /// Tears the mirror down and hands the picture back to `AVPlayerLayer`.
    func stop(restoringSource: Bool = true) {
        displayLink?.invalidate()
        displayLink = nil

        if let videoOutput = output {
            // Hand rendering back *before* detaching, or the player layer stays
            // dark for as long as the item lives.
            videoOutput.suppressesPlayerRendering = false
            observedItem?.remove(videoOutput)
        }
        output = nil
        observedItem = nil

        layer.contents = nil
        layer.removeAllAnimations()
        mirrorView.removeFromSuperview()
        secureCanvas = nil
        zoomTransform = CATransform3DIdentity

        if restoringSource {
            sourceLayer?.isHidden = false
        }
        sourceLayer = nil
        player = nil
        framesDelivered = 0
        conversionFailures = 0
        hasTakenOver = false
    }

    // MARK: - Frame pump

    @objc private func step(_ link: CADisplayLink) {
        guard let videoOutput = output else { return }

        // The item was swapped underneath us (next lesson, re-buffer). The
        // owner's watchdog re-attaches on the next tick.
        if let player = player, player.currentItem !== observedItem {
            stop(restoringSource: true)
            return
        }

        let itemTime = videoOutput.itemTime(forHostTime: link.targetTimestamp)
        guard videoOutput.hasNewPixelBuffer(forItemTime: itemTime) else {
            checkForStall()
            return
        }
        guard let buffer = videoOutput.copyPixelBuffer(
            forItemTime: itemTime,
            itemTimeForDisplay: nil
        ) else {
            checkForStall()
            return
        }

        // A `CGImage` — not the buffer's `IOSurface`. `CALayer.contents` accepts
        // an IOSurface on macOS only; on iOS it is taken without complaint and
        // never drawn, which is exactly how fullscreen ended up black.
        var image: CGImage?
        let status = VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &image)
        guard status == noErr, let frame = image else {
            conversionFailures += 1
            if conversionFailures >= conversionFailureLimit {
                abandon(reason: "cannot convert frames to CGImage (status \(status))")
            }
            return
        }
        conversionFailures = 0

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = frame
        CATransaction.commit()

        if framesDelivered == 0 {
            NSLog("🛡️ [BunnyPlayer] secure video mirror: first frame on screen")
        }
        framesDelivered += 1
        syncPlacement()
        takeOverIfReady()
    }

    /// Once the mirror is demonstrably drawing, take the video away from
    /// `AVPlayerLayer` — the step that makes the picture uncapturable.
    private func takeOverIfReady() {
        guard !hasTakenOver, framesDelivered >= framesBeforeTakeover else { return }
        hasTakenOver = true
        layer.backgroundColor = UIColor.black.cgColor
        output?.suppressesPlayerRendering = true
        sourceLayer?.isHidden = true
        NSLog("🛡️ [BunnyPlayer] secure video mirror took over — video is no longer capturable")
    }

    /// A protected (FairPlay) item hands no pixels to an output. Rather than
    /// leave the viewer staring at a dark player, give the video back.
    private func checkForStall() {
        guard framesDelivered == 0 else { return }
        guard let player = player, player.rate > 0 else { return }
        guard CACurrentMediaTime() - startedAt > 2.5 else { return }
        abandon(reason: "no frames after 2.5s of playback")
    }

    private func abandon(reason: String) {
        NSLog("🛡️ [BunnyPlayer] secure video mirror abandoned — %@", reason)
        abandoned = true
        stop(restoringSource: true)
    }

    deinit {
        displayLink?.invalidate()
        if let videoOutput = output {
            videoOutput.suppressesPlayerRendering = false
            observedItem?.remove(videoOutput)
        }
        sourceLayer?.isHidden = false
    }
}
