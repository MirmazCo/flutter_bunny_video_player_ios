//
//  Bridge.swift
//  Runner
//
//  Created by Roothex200 on 7/9/25.
//

import Foundation
import Flutter
import UIKit

class BunnyPlayerPlatformView: NSObject, FlutterPlatformView {
    private var _view: UIView
    private var _controller: BunnyPlayerViewController
    private var _channel: FlutterMethodChannel?

    init(
        frame: CGRect,
        viewIdentifier viewId: Int64,
        arguments args: Any?,
        messenger: FlutterBinaryMessenger?
    ) {
        let params = args as? [String: Any]


        let playIconAsset = params?["playIconAsset"] as? String ?? ""
        let accessKey = params?["accessKey"]
        let libraryId = params?["libraryId"] as? Int ?? 0
        let videoId = params?["videoId"] as? String ?? ""
        let token = params?["token"] as? String ?? nil
        let expires = params?["expires"] as? Int ?? nil
        let referer = params?["referer"] as? String ?? nil
        let progressIntervalMs = params?["progressIntervalMs"] as? Int ?? 10_000
        let isScreenShotProtectEnable =
            params?["isScreenShotProtectEnable"] as? Bool ?? true
        let watermarkText = params?["watermarkText"] as? String ?? ""
        let startProgressPercent =
            (params?["startProgressPercent"] as? NSNumber)?.doubleValue ?? 0

        let controller = BunnyPlayerViewController(
            accessKey: accessKey as? String ?? nil,
            videoId: videoId,
            libraryId: libraryId,
            playIconAsset: playIconAsset,
            token: token,
            expires: expires,
            referer: referer,
            screenshotProtectionEnabled: isScreenShotProtectEnable,
            watermarkText: watermarkText,
            startProgressPercent: startProgressPercent
        )
        _controller = controller
        _view = controller.view
        super.init()
        NSLog("🟢 [BunnyPlayer] PlatformView init — videoId: %@, viewId: %lld", videoId, viewId)

        if let messenger = messenger {
            let channel = FlutterMethodChannel(
                name: "flutter_bunny_video_player_ios_\(viewId)",
                binaryMessenger: messenger
            )
            channel.setMethodCallHandler { [weak self] call, result in
                self?.handle(call: call, result: result)
            }
            _channel = channel
            NSLog("🟢 [BunnyPlayer] MethodChannel registered: flutter_bunny_video_player_ios_%lld", viewId)
        }

        _controller.onProgress = { [weak self] payload in
            self?._channel?.invokeMethod("progress", arguments: payload)
        }
        _controller.onScreenshotEvent = { [weak self] type, payload in
            self?._channel?.invokeMethod(type, arguments: payload)
        }
        _controller.startProgressReporting(intervalMs: progressIntervalMs)
    }

    private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
        NSLog("📡 [BunnyPlayer] method call: %@", call.method)
        switch call.method {
        case "resetZoom":
            _controller.resetZoomInstant()
            result(nil)
        case "captureFrame":
            _controller.captureCurrentFrame { image, error in
                if let png = image?.pngData() {
                    result(FlutterStandardTypedData(bytes: png))
                } else {
                    result(FlutterError(
                        code: "captureFrame",
                        message: error ?? "Frame capture failed",
                        details: nil
                    ))
                }
            }
        case "takeScreenshot":
            _controller.takeScreenshotInternal { name, error in
                if let n = name {
                    result(n)
                } else {
                    result(FlutterError(
                        code: "takeScreenshot",
                        message: error ?? "Screenshot failed",
                        details: nil
                    ))
                }
            }
        case "dispose":
            _controller.cleanup()
            _channel?.setMethodCallHandler(nil)
            _channel = nil
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    deinit {
        NSLog("🔴 [BunnyPlayer] PlatformView deinit — disposing platform view")
        _channel?.setMethodCallHandler(nil)
        _channel = nil
        _controller.cleanup()
        NSLog("🔴 [BunnyPlayer] PlatformView deinit — cleanup finished")
    }

    func view() -> UIView {
        return _view
    }
}

public class BunnyPlayerPlatformViewFactory: NSObject, FlutterPlatformViewFactory {
    private var messenger: FlutterBinaryMessenger

    init(messenger: FlutterBinaryMessenger) {
        self.messenger = messenger
        super.init()
    }

    public func create(
        withFrame frame: CGRect,
        viewIdentifier viewId: Int64,
        arguments args: Any?
    ) -> FlutterPlatformView {
        return BunnyPlayerPlatformView(frame: frame, viewIdentifier: viewId, arguments: args, messenger: messenger)
    }

    public func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
        return FlutterStandardMessageCodec.sharedInstance()
    }
}

