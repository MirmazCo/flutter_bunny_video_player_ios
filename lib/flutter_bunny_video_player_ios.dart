import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// A playback-position snapshot pushed by the native player.
///
/// Emitted on a timer (see [BunnyIosPlayerView.progressInterval]) so a host
/// app can persist watch progress without polling. [percent] is already scaled
/// 0–100 for APIs that store lesson progress that way.
@immutable
class BunnyPlaybackProgress {
  const BunnyPlaybackProgress({
    required this.position,
    required this.duration,
    required this.percent,
    required this.isPlaying,
  });

  final Duration position;
  final Duration duration;

  /// Position as a percentage of [duration], in the range 0–100.
  final double percent;

  final bool isPlaying;

  factory BunnyPlaybackProgress._fromMap(Map<Object?, Object?> map) {
    final int positionMs = (map['positionMs'] as num?)?.toInt() ?? 0;
    final int durationMs = (map['durationMs'] as num?)?.toInt() ?? 0;
    final double percent = (map['percent'] as num?)?.toDouble() ??
        (durationMs > 0 ? positionMs / durationMs * 100.0 : 0.0);
    return BunnyPlaybackProgress(
      position: Duration(milliseconds: positionMs),
      duration: Duration(milliseconds: durationMs),
      percent: percent,
      isPlaying: map['isPlaying'] as bool? ?? false,
    );
  }

  @override
  String toString() =>
      'BunnyPlaybackProgress(${percent.toStringAsFixed(1)}%, '
      '${position.inSeconds}s / ${duration.inSeconds}s, playing: $isPlaying)';
}

/// Result of a screenshot save attempt. [name] is the gallery asset
/// identifier on success, [error] holds the failure reason otherwise.
class ScreenshotResult {
  final String? name;
  final String? error;
  const ScreenshotResult({this.name, this.error});
  bool get success => name != null;
}

class BunnyPlayerController {
  MethodChannel? _channel;
  bool _disposed = false;
  ValueChanged<BunnyPlaybackProgress>? onProgress;
  final _screenshotController = StreamController<ScreenshotResult>.broadcast();

  bool get isDisposed => _disposed;

  /// Fires whenever the user taps the native screenshot button or the app
  /// calls [takeScreenshot]. Emits both success and failure results.
  Stream<ScreenshotResult> get screenshotStream => _screenshotController.stream;

  void _attach(int viewId) {
    _channel?.setMethodCallHandler(null);
    final MethodChannel channel =
        MethodChannel('flutter_bunny_video_player_ios_$viewId');
    channel.setMethodCallHandler(_handleCall);
    _channel = channel;
  }

  Future<void> _handleCall(MethodCall call) async {
    if (_disposed) return;
    switch (call.method) {
      case 'progress':
        final Object? args = call.arguments;
        if (args is! Map<Object?, Object?>) return;
        onProgress?.call(BunnyPlaybackProgress._fromMap(args));
        break;
      case 'screenshotSaved':
        final Object? args = call.arguments;
        if (args is Map) {
          _screenshotController.add(ScreenshotResult(
            name: args['name'] as String?,
          ));
        }
        break;
      case 'screenshotFailed':
        final Object? args = call.arguments;
        if (args is Map) {
          _screenshotController.add(ScreenshotResult(
            error: args['error'] as String? ?? 'Unknown error',
          ));
        }
        break;
    }
  }

  /// Reset zoom to default (1.0x scale, centered)
  Future<void> resetZoom() async {
    if (_disposed) return;
    await _channel?.invokeMethod('resetZoom');
  }

  /// Captures the current playback frame as raw PNG bytes (no watermark,
  /// no save). Useful when the host app wants to handle compositing or
  /// persistence itself. Returns null if the native side could not produce
  /// a frame (e.g. video not yet ready).
  Future<Uint8List?> captureFrame() async {
    if (_disposed) return null;
    try {
      final result = await _channel?.invokeMethod<Uint8List?>('captureFrame');
      return result;
    } on PlatformException {
      return null;
    }
  }

  /// Captures the current frame, composites the configured `watermarkText`
  /// in the top-left corner natively, and saves the result to the Photos
  /// library. Returns a [ScreenshotResult] with the gallery asset name on
  /// success or an error string on failure. Same result is also delivered
  /// via [screenshotStream].
  Future<ScreenshotResult> takeScreenshot() async {
    if (_disposed) {
      return const ScreenshotResult(error: 'Controller disposed');
    }
    try {
      final name = await _channel?.invokeMethod<String>('takeScreenshot');
      return ScreenshotResult(name: name);
    } on PlatformException catch (e) {
      return ScreenshotResult(error: e.message ?? 'Unknown error');
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    try {
      await _channel?.invokeMethod('dispose');
    } catch (_) {
      // Native side may already be torn down (widget disposed first); safe to ignore.
    }
    _channel?.setMethodCallHandler(null);
    _channel = null;
    onProgress = null;
    await _screenshotController.close();
  }
}

class BunnyIosPlayerView extends StatefulWidget {
  final BunnyPlayerController? controller;
  final String? accessKey;
  final String videoId;
  final int libraryId;
  final String? playIconAsset;
  final String? token;
  final int? expires;
  final String? referer;

  /// Whether the native fullscreen player is hosted inside a secure canvas, so
  /// screenshots, screen recordings and AirPlay mirrors never contain the
  /// video — and whether it keeps the display awake in fullscreen.
  ///
  /// Nothing is blanked, dimmed or paused: the picture the viewer sees is
  /// untouched, the video simply is not in the buffer the capture pipeline
  /// reads. iOS has no `FLAG_SECURE` equivalent, so this covers the SDK's
  /// fullscreen cover only; the inline player stays the host app's
  /// `ScreenProtector.preventScreenshotOn()` job.
  final bool isScreenShotProtectEnable;

  /// User-id (or other) text floated over the video. Empty / null = no watermark.
  ///
  /// Drawn natively so it also appears inside the SDK's `.fullScreenCover`,
  /// which a Flutter overlay cannot reach.
  final String? watermarkText;

  /// Where to resume playback, as a percentage of duration (0–100).
  ///
  /// Comes from `get_lesson_by_id.progress`. Sought once after the AVPlayer
  /// item duration is known.
  final double startProgressPercent;

  /// How often the native player reports [BunnyPlaybackProgress].
  ///
  /// Defaults to 10 seconds. Host apps that cache for a lifecycle flush
  /// typically pass `Duration(milliseconds: 500)`. Pass [Duration.zero] to
  /// turn reporting off.
  final Duration progressInterval;

  /// Called on every progress tick. Requires a positive [progressInterval].
  ///
  /// Also assigned onto [controller].onProgress when a controller is supplied,
  /// so callers listening there keep working.
  final ValueChanged<BunnyPlaybackProgress>? onProgress;

  /// Language for the player's own menus (Quality / Speed / Captions / Cancel),
  /// as a language code such as `'ar'` or `'en'`.
  ///
  /// Those menus are drawn and localized natively, and iOS resolves their strings
  /// against the *device* language — an Arabic app on an English phone would show
  /// English menus. Pass the language the app itself is running in. Null keeps
  /// the device's own resolution.
  final String? languageCode;

  const BunnyIosPlayerView({
    super.key,
    this.controller,
    required this.accessKey,
    required this.videoId,
    required this.libraryId,
    this.playIconAsset,
    this.token,
    this.expires,
    this.referer,
    this.isScreenShotProtectEnable = true,
    this.watermarkText,
    this.startProgressPercent = 0.0,
    this.progressInterval = const Duration(seconds: 10),
    this.onProgress,
    this.languageCode,
  });

  @override
  State<BunnyIosPlayerView> createState() => _BunnyPlayerViewState();
}

class _BunnyPlayerViewState extends State<BunnyIosPlayerView> {
  late final BunnyPlayerController _controller =
      widget.controller ?? BunnyPlayerController();
  late final bool _ownsController = widget.controller == null;

  @override
  void initState() {
    super.initState();
    _syncProgressCallback();
  }

  @override
  void didUpdateWidget(BunnyIosPlayerView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.onProgress != widget.onProgress) {
      _syncProgressCallback();
    }
  }

  void _syncProgressCallback() {
    if (widget.onProgress != null) {
      _controller.onProgress = widget.onProgress;
    }
  }

  @override
  void dispose() {
    if (_ownsController) {
      _controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const viewType = 'bunny_player_view_ios';

    if (Platform.isIOS) {
      return UiKitView(
        viewType: viewType,
        layoutDirection: TextDirection.ltr,
        hitTestBehavior: PlatformViewHitTestBehavior.opaque,
        // Without this, Flutter's touch interceptor holds every touch sequence
        // until its own arena resolves and only then replays it to the native
        // view. A single tap survives that round trip, which is why the SDK's
        // controls respond, but a two-finger pinch does not: the native
        // UIPinchGestureRecognizer never sees the second touch begin. Claiming
        // the arena eagerly hands the raw touches straight to UIKit, which is
        // what the pinch/pan/double-tap recognizers in
        // `BunnyPlayerViewController` need. Same as `bunny_stream_player`.
        gestureRecognizers: <Factory<OneSequenceGestureRecognizer>>{
          Factory<EagerGestureRecognizer>(() => EagerGestureRecognizer()),
        },
        onPlatformViewCreated: (int id) {
          _controller._attach(id);
          _syncProgressCallback();
        },
        creationParams: {
          'accessKey': widget.accessKey,
          'videoId': widget.videoId,
          'libraryId': widget.libraryId,
          'playIconAsset': widget.playIconAsset,
          'token': widget.token,
          'expires': widget.expires,
          'referer': widget.referer,
          'progressIntervalMs': widget.progressInterval.inMilliseconds,
          'isScreenShotProtectEnable': widget.isScreenShotProtectEnable,
          'watermarkText': widget.watermarkText ?? '',
          'startProgressPercent': widget.startProgressPercent,
          'languageCode': widget.languageCode ?? '',
        },
        creationParamsCodec: const StandardMessageCodec(),
      );
    }
    return Container();
  }
}
