//
//  BunnyPlayerViewController.swift
//  Runner
//
//  Created by Roothex200 on 7/9/25.
//

import Foundation
import SwiftUI
import UIKit
import AVFoundation
import BunnyStreamPlayer
import Flutter
class BunnyPlayerViewController: UIViewController {
    let accessKey: String?
    let videoId: String
    let libraryId: Int
    let playIconAsset: String
    let token: String?
    let expires: Int?
    let referer: String?
    private weak var avPlayer: AVPlayer?

    /// When true, the player keeps the screen awake in fullscreen and hosts the
    /// fullscreen cover inside a secure canvas, so screenshots, screen
    /// recordings and AirPlay mirrors never contain the video. Playback itself
    /// is never interrupted and the picture is never blanked — see
    /// `NativeScreenshotShield`.
    private let screenshotProtectionEnabled: Bool

    /// User-id text floated over the video. Empty = no watermark.
    private let watermarkText: String

    /// Resume position as a percentage of duration (0–100), from the lesson API.
    private let startProgressPercent: Double
    private var startSeekApplied = false
    /// True once a resume seek has been kicked off (prevents double seek).
    private var startSeekInFlight = false

    /// Pushes a progress snapshot to Dart. Wired by `BunnyPlayerPlatformView`.
    var onProgress: (([String: Any]) -> Void)?

    private var progressTimer: Timer?

    private var watermarkView: NativeWatermarkView?

    /// Draws the fullscreen video through CoreAnimation so the secure canvas
    /// can exclude it from captures — `AVPlayerLayer` output cannot be
    /// excluded, whatever it is parented under. See `SecureVideoMirror`.
    private let secureVideoMirror = SecureVideoMirror()

    private var isInFullscreen = false
    private var idleTimerDisabledByUs = false

    // MARK: - Zoom State

    private var currentZoomScale: CGFloat = 1.0
    private var currentZoomTranslation: CGPoint = .zero
    private let minZoomScale: CGFloat = 1.0
    private let maxZoomScale: CGFloat = 4.0
    private let zoomSnapThreshold: CGFloat = 1.05
    private var panStartTranslation: CGPoint = .zero

    /// The view the zoom currently applies to: our own view inline, or the
    /// SDK's fullscreen view while it is presented.
    ///
    /// Fullscreen is `.fullScreenCover(isPresented:)` inside
    /// `BunnyStreamPlayerContainerView`, which builds a *second* copy of the
    /// player view in a modally presented hierarchy — a different view, with a
    /// different `AVPlayerLayer`, outside this view controller's view entirely.
    /// Gestures bound to `view` never see those touches and the zoom container
    /// wraps the inline layer, which is why zoom worked inline and did nothing
    /// once fullscreen opened.
    private weak var zoomHostView: UIView?

    /// The player area on screen right now.
    private func resolveZoomHost() -> UIView {
        return fullscreenPlayerView() ?? view
    }

    /// The presented fullscreen player view, if the SDK has one up.
    ///
    /// Deliberately *not* walked from `window.rootViewController`: Flutter only
    /// takes this controller's `view`, so the controller itself never joins the
    /// window's view-controller hierarchy. SwiftUI therefore presents the cover
    /// from our own child `UIHostingController`, and the presented controller
    /// hangs off that — the window root's `presentedViewController` stays nil,
    /// which is why looking there found nothing and fullscreen zoom stayed dead.
    private func fullscreenPlayerView() -> UIView? {
        // 1. The presentation chain that starts at our hosting controller.
        var controller: UIViewController? = children.first
        var presented: UIViewController? = nil
        while let next = controller?.presentedViewController {
            presented = next
            controller = next
        }
        if let candidate = presented?.view,
           Self.findPlayerLayer(in: candidate) != nil {
            return candidate
        }

        // 2. Fallback for presentations UIKit re-routes elsewhere (including
        //    into a separate window): anything on screen that owns a player
        //    layer and is not the branch this inline player lives in.
        guard let window = view.window else { return nil }
        let windows: [UIWindow] = window.windowScene?.windows ?? [window]
        for candidateWindow in windows.reversed() where !candidateWindow.isHidden {
            for subview in candidateWindow.subviews.reversed() {
                if view.isDescendant(of: subview) { continue }
                if Self.findPlayerLayer(in: subview) != nil { return subview }
            }
        }
        return nil
    }

    /// The SDK builds its player layer inside a SwiftUI hierarchy, so we can't
    /// hold it at init time — look it up lazily and re-resolve if the hierarchy
    /// is rebuilt (the layer only exists once the video finishes loading).
    /// Cached per host: inline and fullscreen have one player layer each, so the
    /// cache is only valid while the host it was found in is still the active
    /// one.
    private weak var cachedPlayerLayer: AVPlayerLayer?
    private weak var cachedPlayerLayerHost: UIView?

    private var playerLayer: AVPlayerLayer? {
        let host: UIView = zoomHostView ?? view
        if let layer = cachedPlayerLayer,
           layer.superlayer != nil,
           cachedPlayerLayerHost === host {
            return layer
        }
        cachedPlayerLayer = Self.findPlayerLayer(in: host)
        cachedPlayerLayerHost = cachedPlayerLayer == nil ? nil : host
        return cachedPlayerLayer
    }

    /// The SwiftUI host, kept as the zoom target of last resort.
    private weak var hostView: UIView?

    /// A layer we own, spliced in between the SDK's view layer and its
    /// `AVPlayerLayer`, and the thing the zoom transform is applied to.
    ///
    /// This indirection is the whole reason zoom works. The SDK's player view
    /// controller does exactly this on every layout pass of its own view:
    ///
    ///     override func viewDidLayoutSubviews() {
    ///         playerLayer.frame = view.frame
    ///     }
    ///
    /// `frame` is derived from `bounds`, `position` **and `transform`**, so
    /// assigning it to a layer that carries a 2× scale shrinks the layer's
    /// bounds to half, leaving the scaled result covering exactly the same
    /// rectangle as before. The zoom was being applied and then silently
    /// cancelled — which is why pinching looked like it did nothing at all.
    /// Compensating in our own `viewDidLayoutSubviews` was not enough: the SDK
    /// re-lays out on its own (the controls tick the playhead constantly) while
    /// our view stays clean and never gets a layout pass.
    ///
    /// Transforming a container the SDK has never heard of ends the fight. It
    /// keeps assigning `playerLayer.frame` inside the container's untransformed
    /// coordinate space, exactly as it expects, and the zoom rides on top.
    private weak var zoomContainerLayer: CALayer?

    /// The layer the current transform sits on, so it can be reset when the
    /// target changes.
    private weak var lastZoomTarget: CALayer?

    /// What the zoom transform is actually applied to: our container when the
    /// SDK's layer has been found, otherwise the SwiftUI host as a last resort
    /// so the gesture always has something to scale.
    private var zoomTargetLayer: CALayer? {
        return ensureZoomContainer() ?? hostView?.layer
    }

    /// Installs (or re-installs, if the SwiftUI hierarchy was rebuilt) the
    /// container layer around the SDK's `AVPlayerLayer`.
    @discardableResult
    private func ensureZoomContainer() -> CALayer? {
        guard let playerLayer = playerLayer else { return nil }

        if let container = zoomContainerLayer,
           playerLayer.superlayer === container,
           container.superlayer != nil {
            return container
        }

        guard let host = playerLayer.superlayer else { return nil }

        let container = CALayer()
        container.masksToBounds = false
        // Geometry set through bounds/position rather than frame: frame would
        // be read back through whatever transform is applied at the time.
        container.bounds = CGRect(origin: .zero, size: host.bounds.size)
        container.position = CGPoint(x: host.bounds.midX, y: host.bounds.midY)

        let index = host.sublayers?.firstIndex(of: playerLayer) ?? 0
        playerLayer.removeFromSuperlayer()
        container.addSublayer(playerLayer)
        host.insertSublayer(container, at: UInt32(index))
        playerLayer.frame = container.bounds

        zoomContainerLayer = container
        NSLog("🔍 [BunnyPlayer] zoom container installed around AVPlayerLayer")
        return container
    }

    init(accessKey: String?, videoId: String, libraryId: Int,playIconAsset: String
         ,token:String?,expires:Int?,referer:String?,
         screenshotProtectionEnabled: Bool = true,
         watermarkText: String = "",
         startProgressPercent: Double = 0) {
        self.accessKey = accessKey
        self.videoId = videoId
        self.libraryId = libraryId
        self.playIconAsset = playIconAsset
        self.token=token
        self.referer = referer
        self.expires=expires
        self.screenshotProtectionEnabled = screenshotProtectionEnabled
        self.watermarkText = watermarkText
        self.startProgressPercent = startProgressPercent
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // Zoomed video must not spill outside the platform view's bounds.
        view.clipsToBounds = true

        let iconImage = loadFlutterAsset(named: playIconAsset)
        let icons = PlayerIcons(play: iconImage)
        
        let playerView = BunnyFlutterPlayer(
            accessKey: accessKey,
            videoId: videoId,
            libraryId: libraryId,
            playerIcons: icons,
            token: token,
            expires: expires,
            referer: referer,
            onPlayerReady: { [weak self] player in
                NSLog("🎬 [BunnyPlayer] onPlayerReady — captured AVPlayer reference")
                self?.avPlayer = player
                self?.seekToStartProgressIfNeeded(player: player)
            }
        )

        let hostingController = UIHostingController(rootView: playerView)
        hostView = hostingController.view
        addChild(hostingController)
        // Auto layout to match Flutter size
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hostingController.view)
        hostingController.didMove(toParent: self)

        NSLayoutConstraint.activate([
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
       // hostingController.didMove(toParent: self)

        setupZoomGestures()
        startHostWatchdog()
        attachWatermark(to: view)
        if screenshotProtectionEnabled {
            startScreenshotProtection()
        }
    }

    // MARK: - Start progress seek

    /// Seeks once to [startProgressPercent] after the item duration is known.
    ///
    /// Same gate as `bunny_stream_player`: `pause` → seek → `play` so the user
    /// never sees 0:00 then a jump. `0` skips the seek entirely.
    ///
    /// [startSeekApplied] flips only after the seek completes (or is abandoned),
    /// so [emitProgress] never publishes the opening 0% frame to the host.
    private func seekToStartProgressIfNeeded(player: AVPlayer) {
        guard startProgressPercent > 0, !startSeekApplied, !startSeekInFlight else { return }
        guard let item = player.currentItem else { return }

        // Don't show the opening frame before the seek lands.
        player.pause()
        startSeekInFlight = true

        item.asset.loadValuesAsynchronously(forKeys: ["duration"]) { [weak self] in
            DispatchQueue.main.async {
                guard let self = self, !self.startSeekApplied else { return }
                var error: NSError?
                let status = item.asset.statusOfValue(forKey: "duration", error: &error)
                guard status == .loaded else {
                    self.startSeekApplied = true
                    player.play()
                    return
                }
                let duration = item.asset.duration
                guard duration.isNumeric, !duration.isIndefinite else {
                    self.startSeekApplied = true
                    player.play()
                    return
                }
                let durationSec = CMTimeGetSeconds(duration)
                guard durationSec.isFinite, durationSec > 0 else {
                    self.startSeekApplied = true
                    player.play()
                    return
                }

                let targetSec = min(
                    max(self.startProgressPercent / 100.0 * durationSec, 0),
                    durationSec
                )
                let target = CMTime(seconds: targetSec, preferredTimescale: 600)
                NSLog(
                    "🎬 [BunnyPlayer] start seek → %.1fs (%.2f%% of %.1fs)",
                    targetSec, self.startProgressPercent, durationSec
                )
                player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                    self.startSeekApplied = true
                    player.play()
                }
            }
        }
    }

    // MARK: - Progress reporting

    /// Starts a repeating timer that pushes playhead snapshots to [onProgress].
    ///
    /// Pass `intervalMs <= 0` to leave reporting off. Ticks fire whenever
    /// duration is known (playing or paused) — matching Android / AppBunny —
    /// so a lifecycle flush after pause still has a fresh playhead.
    func startProgressReporting(intervalMs: Int) {
        progressTimer?.invalidate()
        progressTimer = nil
        guard intervalMs > 0 else { return }
        let interval = TimeInterval(intervalMs) / 1000.0
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.emitProgress()
        }
        // Platform views can sit outside the default run-loop mode while
        // scrolling; `.common` keeps the tick alive then.
        RunLoop.main.add(timer, forMode: .common)
        progressTimer = timer
    }

    private func emitProgress() {
        // Hold ticks until the resume seek lands — otherwise the host caches
        // 0% and lifecycle flush wipes the saved lesson progress.
        if startProgressPercent > 0, !startSeekApplied { return }

        guard let player = avPlayer, let item = player.currentItem else { return }
        let duration = CMTimeGetSeconds(item.duration)
        guard duration.isFinite, duration > 0 else { return }
        let position = CMTimeGetSeconds(player.currentTime())
        guard position.isFinite, position >= 0 else { return }
        let clamped = min(position, duration)
        let percent = (clamped / duration) * 100.0
        onProgress?([
            "positionMs": Int64(clamped * 1000),
            "durationMs": Int64(duration * 1000),
            "percent": percent,
            "isPlaying": player.rate > 0,
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        // Entering or leaving fullscreen relays out the inline player too, so
        // this catches the swap without waiting for the watchdog tick.
        syncZoomHost()

        // Keep the container matching the area the SDK lays its player layer
        // out in. Written as bounds + position because `frame` is relative to
        // the transform we are about to re-apply.
        if let container = ensureZoomContainer(), let host = container.superlayer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            container.bounds = CGRect(origin: .zero, size: host.bounds.size)
            container.position = CGPoint(x: host.bounds.midX, y: host.bounds.midY)
            // The SDK assigns `playerLayer.frame = view.frame`, which carries
            // the host view's origin; inside the container the origin must be
            // zero or the video sits offset.
            cachedPlayerLayer?.frame = container.bounds
            CATransaction.commit()
        }

        // The mirror rides inside the same container as the layer it replaces,
        // so it picks up the zoom transform — but its frame has to follow the
        // player layer the SDK has just rewritten.
        if secureVideoMirror.isRunning {
            secureVideoMirror.syncPlacement()
        }

        currentZoomTranslation = clampZoomTranslation(currentZoomTranslation)
        applyZoomTransform()
    }

    // MARK: - Zoom Gestures

    private func setupZoomGestures() {
        attachGesturesIfNeeded(to: view)
    }

    private func addZoomGestures(to target: UIView) {
        // Double-tap to reset zoom
        let doubleTapGesture = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTapGesture.numberOfTapsRequired = 2
        doubleTapGesture.delegate = self
        doubleTapGesture.cancelsTouchesInView = false
        target.addGestureRecognizer(doubleTapGesture)

        // Pinch to zoom
        let pinchGesture = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinchGesture.delegate = self
        pinchGesture.cancelsTouchesInView = false
        target.addGestureRecognizer(pinchGesture)

        // Pan when zoomed
        let zoomPanGesture = UIPanGestureRecognizer(target: self, action: #selector(handleZoomPan(_:)))
        zoomPanGesture.minimumNumberOfTouches = 1
        zoomPanGesture.maximumNumberOfTouches = 1
        zoomPanGesture.delegate = self
        zoomPanGesture.cancelsTouchesInView = false
        target.addGestureRecognizer(zoomPanGesture)
    }

    /// Views that already carry our recognisers, so the watchdog below doesn't
    /// stack duplicates. Weak, because the fullscreen view dies with each
    /// presentation.
    private let gesturedHosts = NSHashTable<UIView>.weakObjects()

    /// Fullscreen is a modal presentation with its own view tree, and this
    /// controller is detached from the view-controller hierarchy, so nothing
    /// tells us when it appears — no `viewWillAppear`, no delegate, no
    /// notification. A 2 Hz check is the reliable way to notice the swap and
    /// bind the gestures to the new player before the user pinches it.
    private var hostWatchdog: Timer?

    private func startHostWatchdog() {
        guard hostWatchdog == nil else { return }
        hostWatchdog = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.syncZoomHost()
        }
    }

    private func attachGesturesIfNeeded(to host: UIView) {
        guard !gesturedHosts.contains(host) else { return }
        addZoomGestures(to: host)
        gesturedHosts.add(host)
        NSLog(
            "🔍 [BunnyPlayer] zoom gestures attached to %@",
            host === view ? "inline player" : "fullscreen player"
        )
    }

    /// Points the zoom at whatever player is on screen, resetting the previous
    /// one: inline and fullscreen have different geometry, and carrying a scale
    /// across the transition would land the video off-centre.
    private func syncZoomHost() {
        let host = resolveZoomHost()
        attachGesturesIfNeeded(to: host)

        let nowFullscreen = host !== view
        if nowFullscreen != isInFullscreen {
            isInFullscreen = nowFullscreen
            onFullscreenChanged(nowFullscreen)
        }

        // Re-assert on every tick, not just on the swap: the SDK rebuilds parts
        // of its SwiftUI hierarchy while playing, and anything it adds after the
        // install would otherwise sit outside the secure canvas. `protect` is
        // idempotent, so this is a no-op once everything is inside.
        if screenshotProtectionEnabled {
            ensureSecureVideoMirror()
        }

        guard host !== zoomHostView else { return }

        if zoomHostView != nil {
            resetZoomInstant()
        }
        zoomHostView = host
        cachedPlayerLayer = nil
        cachedPlayerLayerHost = nil
        zoomContainerLayer = nil
        currentZoomScale = 1.0
        currentZoomTranslation = .zero
        // The watermark follows the active host (inline ↔ fullscreen).
        attachWatermark(to: host)
        NSLog(
            "🔍 [BunnyPlayer] zoom host is now %@",
            host === view ? "inline player" : "fullscreen player"
        )
    }

    // MARK: - Watermark

    /// Pins the floating user-id overlay onto [host] (inline or fullscreen).
    ///
    /// Reparents a single view so the watermark never disappears when the SDK
    /// presents its `.fullScreenCover` — a Flutter overlay cannot follow that
    /// modal hierarchy.
    private func attachWatermark(to host: UIView) {
        guard !watermarkText.isEmpty else { return }
        let wm = watermarkView ?? NativeWatermarkView(frame: host.bounds)
        wm.setText(watermarkText)
        wm.frame = host.bounds
        wm.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        if wm.superview !== host {
            wm.removeFromSuperview()
            host.addSubview(wm)
        }
        host.bringSubviewToFront(wm)
        watermarkView = wm
    }

    // MARK: - Fullscreen keep-awake + screenshot shield

    /// Orientation is deliberately left to the SDK and the device.
    ///
    /// This used to force `.landscape` on the window scene when the cover went
    /// up and `.all` when it came down, to match Android's
    /// `SENSOR_LANDSCAPE`. On iOS that is a poor trade: `requestGeometryUpdate`
    /// rotates the *scene* underneath a cover the SDK has already laid out, and
    /// the presented hierarchy is rebuilt around the new size while the
    /// controls' hit-test geometry lags behind — which is what made the
    /// fullscreen buttons hard to press. Letting the cover rotate naturally is
    /// both simpler and correct.
    private func onFullscreenChanged(_ fullscreen: Bool) {
        guard screenshotProtectionEnabled else { return }
        if fullscreen {
            // Keep the display awake in the fullscreen cover. Do not undo this
            // on exit — the host (lesson KeepAwakeService) may still need it,
            // and cleanup() restores the previous value when the player dies.
            if !UIApplication.shared.isIdleTimerDisabled {
                UIApplication.shared.isIdleTimerDisabled = true
                idleTimerDisabledByUs = true
            }
        }
        // Each mode has its own AVPlayerLayer, so the mirror re-targets on the
        // swap rather than stopping. Retried from the watchdog too: the cover's
        // player layer does not exist on the first frame.
        ensureSecureVideoMirror()
    }

    /// Watches the events that can invalidate the shield.
    ///
    /// Nothing here blanks, dims or pauses anything — that whole approach is
    /// gone. Protection is structural (`NativeScreenshotShield`), so these
    /// observers only re-assert the shield at the moments UIKit is most likely
    /// to have rebuilt the cover's view tree underneath it.
    ///
    /// The inline Flutter platform view is deliberately never shielded — moving
    /// its subviews breaks the embedding. Inline capture stays the host app's
    /// `screen_protector` job on `FlutterViewController.view`.
    private func startScreenshotProtection() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(reassertScreenshotShield),
            name: UIScreen.capturedDidChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(reassertScreenshotShield),
            name: UIApplication.userDidTakeScreenshotNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(reassertScreenshotShield),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    @objc private func reassertScreenshotShield() {
        guard screenshotProtectionEnabled else { return }
        ensureSecureVideoMirror()
    }

    /// Hands the picture to the CoreAnimation mirror, inline and fullscreen.
    ///
    /// Retried on every watchdog tick because the SDK's `AVPlayerLayer` and the player
    /// item both show up asynchronously, well after the cover is presented.
    private func ensureSecureVideoMirror() {
        guard screenshotProtectionEnabled else { return }
        guard let player = avPlayer, let source = playerLayer else { return }

        // The container goes inside the SDK's own video surface — inline as well
        // as fullscreen. Nothing is reparented, so this is safe on the embedded
        // Flutter platform view, which the adoption shield can never touch.
        let host: UIView = zoomHostView ?? view
        guard let surface = NativeScreenshotShield.videoSurfaceView(in: host) else { return }
        guard let canvas = NativeScreenshotShield.secureCanvas(in: surface) else {
            if !loggedUnsecuredPlayer {
                loggedUnsecuredPlayer = true
                NSLog("🛡️ [BunnyPlayer] no secure canvas for the video surface — mirror not started")
            }
            return
        }
        secureVideoMirror.attach(player: player, source: source, canvas: canvas)
    }

    private var loggedUnsecuredPlayer = false

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            syncZoomHost()
            NSLog(
                "🔍 [BunnyPlayer] pinch began — target: %@",
                playerLayer != nil ? "AVPlayerLayer" : (hostView != nil ? "hostView" : "none")
            )
            zoomTargetLayer?.removeAnimation(forKey: "resetZoom")
        case .changed:
            let host: UIView = zoomHostView ?? view
            let oldScale = currentZoomScale
            let newScale = min(max(currentZoomScale * gesture.scale, minZoomScale), maxZoomScale)
            gesture.scale = 1.0
            // Focal-point zoom: keep the pinch center visually stable
            let focus = gesture.location(in: host)
            let focalRelX = focus.x - host.bounds.midX
            let focalRelY = focus.y - host.bounds.midY
            currentZoomTranslation.x += focalRelX * (oldScale - newScale)
            currentZoomTranslation.y += focalRelY * (oldScale - newScale)
            currentZoomScale = newScale
            currentZoomTranslation = clampZoomTranslation(currentZoomTranslation)
            applyZoomTransform()
        case .ended, .cancelled:
            if currentZoomScale < zoomSnapThreshold {
                animateResetZoom()
            }
        default: break
        }
    }

    @objc private func handleZoomPan(_ gesture: UIPanGestureRecognizer) {
        guard currentZoomScale > zoomSnapThreshold else { return }
        switch gesture.state {
        case .began:
            panStartTranslation = currentZoomTranslation
        case .changed:
            let t = gesture.translation(in: zoomHostView ?? view)
            let newTranslation = CGPoint(x: panStartTranslation.x + t.x, y: panStartTranslation.y + t.y)
            currentZoomTranslation = clampZoomTranslation(newTranslation)
            applyZoomTransform()
        default: break
        }
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        syncZoomHost()
        if currentZoomScale > zoomSnapThreshold {
            animateResetZoom()
        }
    }

    private func applyZoomTransform() {
        let zoom = CATransform3DConcat(
            CATransform3DMakeScale(currentZoomScale, currentZoomScale, 1),
            CATransform3DMakeTranslation(currentZoomTranslation.x, currentZoomTranslation.y, 0)
        )
        // The mirror draws the picture the viewer actually sees, and it lives
        // outside the zoom container, so it needs the transform directly.
        secureVideoMirror.applyZoom(zoom)

        guard let target = zoomTargetLayer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // A pinch that started before the video finished loading scales the
        // SwiftUI host; once the SDK's layer shows up the target switches to the
        // container, so the old one has to be handed back untransformed.
        if let previous = lastZoomTarget, previous !== target {
            previous.transform = CATransform3DIdentity
        }
        lastZoomTarget = target
        let scale = CATransform3DMakeScale(currentZoomScale, currentZoomScale, 1)
        let translate = CATransform3DMakeTranslation(currentZoomTranslation.x, currentZoomTranslation.y, 0)
        target.transform = CATransform3DConcat(scale, translate)
        CATransaction.commit()
    }

    private func clampZoomTranslation(_ t: CGPoint) -> CGPoint {
        guard currentZoomScale > 1.0 else { return .zero }
        let host: UIView = zoomHostView ?? view
        let maxX = host.bounds.width * (currentZoomScale - 1) / 2
        let maxY = host.bounds.height * (currentZoomScale - 1) / 2
        return CGPoint(
            x: min(max(t.x, -maxX), maxX),
            y: min(max(t.y, -maxY), maxY)
        )
    }

    private func animateResetZoom() {
        // Animate the mirror alongside the real player — it is the visible one,
        // so a snap here is what the viewer would see.
        secureVideoMirror.applyZoom(
            CATransform3DIdentity,
            animatedFrom: CATransform3DConcat(
                CATransform3DMakeScale(currentZoomScale, currentZoomScale, 1),
                CATransform3DMakeTranslation(
                    currentZoomTranslation.x, currentZoomTranslation.y, 0
                )
            )
        )

        guard let target = zoomTargetLayer else {
            currentZoomScale = 1.0
            currentZoomTranslation = .zero
            return
        }
        let fromTransform = target.transform
        target.transform = CATransform3DIdentity

        let anim = CABasicAnimation(keyPath: "transform")
        anim.fromValue = fromTransform
        anim.toValue = CATransform3DIdentity
        anim.duration = 0.25
        anim.timingFunction = CAMediaTimingFunction(name: .easeOut)

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            self?.zoomTargetLayer?.removeAnimation(forKey: "resetZoom")
        }
        target.add(anim, forKey: "resetZoom")
        CATransaction.commit()

        currentZoomScale = 1.0
        currentZoomTranslation = .zero
    }

    func resetZoomInstant() {
        currentZoomScale = 1.0
        currentZoomTranslation = .zero
        secureVideoMirror.applyZoom(CATransform3DIdentity)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        zoomTargetLayer?.transform = CATransform3DIdentity
        CATransaction.commit()
    }

    /// Depth-first search for the SDK's `AVPlayerLayer`, which lives on the
    /// layer of a `UIViewController` view nested inside the SwiftUI hierarchy.
    ///
    /// Both trees have to be walked in full. The layer search used to look at
    /// each view's *direct* sublayers only, so a player layer sitting one
    /// container layer deeper was never found — the gestures then had no target
    /// and zoom did nothing at all.
    private static func findPlayerLayer(in view: UIView) -> AVPlayerLayer? {
        if let found = findPlayerLayer(in: view.layer) { return found }
        for subview in view.subviews {
            if let found = findPlayerLayer(in: subview) { return found }
        }
        return nil
    }

    private static func findPlayerLayer(in layer: CALayer) -> AVPlayerLayer? {
        if let playerLayer = layer as? AVPlayerLayer { return playerLayer }
        for sublayer in layer.sublayers ?? [] {
            if let found = findPlayerLayer(in: sublayer) { return found }
        }
        return nil
    }

    func cleanup() {
        NSLog("🧹 [BunnyPlayer] cleanup() called — videoId: %@, children: %d", videoId, children.count)
        // Before the AVPlayer is torn down: the mirror holds a video output on
        // its item and a display link on the main run loop. Restore the source
        // layer on the way out — a hidden player layer is never what we want to
        // leave behind, whatever happens to this controller next.
        secureVideoMirror.stop()
        if let player = avPlayer {
            NSLog("🧹 [BunnyPlayer] tearing down AVPlayer directly (pause + replaceCurrentItem nil)")
            player.pause()
            player.replaceCurrentItem(with: nil)
        } else {
            NSLog("🧹 [BunnyPlayer] no captured AVPlayer — relying on SwiftUI onDisappear teardown")
        }
        avPlayer = nil
        cachedPlayerLayer = nil
        cachedPlayerLayerHost = nil
        // Torn down with the SwiftUI hierarchy it was spliced into; dropping the
        // reference makes the next player build a fresh one.
        zoomContainerLayer?.removeFromSuperlayer()
        zoomContainerLayer = nil
        zoomHostView = nil
        hostWatchdog?.invalidate()
        hostWatchdog = nil
        progressTimer?.invalidate()
        progressTimer = nil
        onProgress = nil
        NotificationCenter.default.removeObserver(self)
        watermarkView?.stopAnimation()
        watermarkView?.removeFromSuperview()
        watermarkView = nil
        isInFullscreen = false
        if idleTimerDisabledByUs {
            UIApplication.shared.isIdleTimerDisabled = false
            idleTimerDisabledByUs = false
        }
        gesturedHosts.removeAllObjects()
        children.forEach { child in
            NSLog("🧹 [BunnyPlayer] removing child: %@", String(describing: type(of: child)))
            child.willMove(toParent: nil)
            child.view.removeFromSuperview()
            child.removeFromParent()
        }
        NSLog("🧹 [BunnyPlayer] cleanup() done")
    }

    deinit {
        NSLog("⚫️ [BunnyPlayer] BunnyPlayerViewController deinit — videoId: %@", videoId)
        hostWatchdog?.invalidate()
        progressTimer?.invalidate()
    }

    /// Height of the bottom strip occupied by the SDK's seek bar. Pans that
    /// start there are left to the seek bar's own drag gesture.
    private let controlsStripHeight: CGFloat = 64

    private func loadFlutterAsset(named asset: String) -> Image {
        let key = FlutterDartProject.lookupKey(forAsset: asset)
        if let path = Bundle.main.path(forResource: key, ofType: nil),
           let uiImage = UIImage(contentsOfFile: path) {
            return Image(uiImage: uiImage)
        } else {
            return Image(systemName: "play.fill")
        }
    }
}

// MARK: - UIGestureRecognizerDelegate

extension BunnyPlayerViewController: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // The player controls live in a SwiftUI overlay with its own
        // recognizers — never block them.
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldReceive touch: UITouch) -> Bool {
        // Each recogniser is bound to the player area it serves — the inline
        // view or the presented fullscreen one — so the geometry to reason
        // about is simply the view it is attached to.
        let host: UIView = gestureRecognizer.view ?? view

        // Pan gesture: only active when zoomed, and never over the controls
        if gestureRecognizer is UIPanGestureRecognizer {
            guard currentZoomScale > zoomSnapThreshold else { return false }
            if let v = touch.view, v is UIControl { return false }
            let location = touch.location(in: host)
            if location.y > host.bounds.height - controlsStripHeight { return false }
            return true
        }
        // Double-tap only resets zoom, so while unzoomed it must not delay the
        // SDK's single tap that toggles the controls.
        if let tap = gestureRecognizer as? UITapGestureRecognizer, tap.numberOfTapsRequired == 2 {
            return currentZoomScale > zoomSnapThreshold
        }
        return true
    }
}

