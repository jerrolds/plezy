import 'dart:math' as math;
import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:rate_limiter/rate_limiter.dart';

import '../mpv/mpv.dart';

import '../utils/app_logger.dart';
import 'ambient_lighting_service.dart';

/// Manages video filtering, aspect ratio modes, and subtitle positioning for video playback.
///
/// This service handles:
/// - BoxFit mode cycling (contain → cover → fill)
/// - Video cropping calculations for fill screen mode
/// - Subtitle positioning adjustments based on crop parameters
/// - Debounced video filter updates on resize events
/// - Ambient-lighting-friendly reset to contain mode
class VideoFilterManager {
  static const double minZoomScale = 0.5;
  static const double maxZoomScale = 2.0;
  static const double zoomStep = 0.01;

  /// How close a pinch has to get to 100%, in whole percent, before it snaps
  /// there exactly.
  ///
  /// [normalizeZoomScale] rounds to whole percent, so an unaided pinch has to
  /// land inside half a percent of 1.0 to undo itself — in practice it leaves
  /// the picture at 99% or 101% and the viewer cannot tell why it still looks
  /// cropped. A detent makes the pinch a reliable inverse of itself.
  ///
  /// Deliberately applied to the pinch handler only, never inside
  /// [normalizeZoomScale]: [zoomStep] is 1%, so a global detent would trap the
  /// keyboard and slider paths at 1.0 with no way to step out.
  static const int pinchZoomResetDetentPercent = 3;

  /// Snaps a pinch-derived [scale] to exactly 1.0 inside the detent.
  ///
  /// Compared in whole percent like [normalizeZoomScale], not in raw doubles:
  /// `(0.97 - 1.0).abs()` is 0.030000000000000027, so a float comparison against
  /// a 0.03 band drops the very boundary it is meant to include.
  static double snapPinchZoomScale(double scale) {
    final percent = (scale * 100).round();
    return (percent - 100).abs() <= pinchZoomResetDetentPercent ? 1.0 : scale;
  }

  final Player player;

  /// Whether [Player.setVideoZoom] scales the native video layer itself, so
  /// the mpv `video-zoom` property must stay 0. On iOS/tvOS the avfoundation
  /// VO re-renders zoomed frames through Core Image, which destroys HDR and
  /// Dolby Vision passthrough — zoom must stay out of mpv's pipeline there.
  final bool nativeVideoZoom;

  /// BoxFit mode state: 0=contain (letterbox), 1=cover (fill screen), 2=fill (stretch)
  int _boxFitMode;

  /// Store the boxFitMode before entering PiP so it can be restored
  int? _prePipBoxFitMode;

  /// Store the zoom level before entering PiP so it can be restored
  double? _prePipZoomScale;

  /// Store whether ambient lighting was active before entering PiP
  bool? _prePipAmbientLighting;

  /// Ambient lighting service reference - when active, video-aspect-override is managed by ambient lighting
  AmbientLightingService? ambientLightingService;

  /// Custom video zoom layered on top of the selected fit mode.
  double _zoomScale = 1.0;

  /// Current player viewport size
  Size? _playerSize;

  /// Debounced video filter update with leading edge execution
  late final Debounce _debouncedUpdateVideoFilter;

  /// Last values actually written to the player. A missing key means unknown,
  /// so the next run rewrites it.
  final Map<String, String> _appliedProps = {};
  int? _appliedBoxFitMode;
  double? _appliedVideoZoom;

  /// Current video content rect within the player (in logical pixels).
  /// When null the content area is unknown; otherwise it describes the
  /// area the decoded video occupies inside the player viewport.
  final ValueNotifier<Rect?> contentRectNotifier = ValueNotifier<Rect?>(null);

  /// Insets (in logical pixels) representing black bars around the content
  /// area: left, top, right, bottom. Zero insets mean the content fills the
  /// player viewport.
  final ValueNotifier<EdgeInsets> blackBarInsetsNotifier = ValueNotifier<EdgeInsets>(EdgeInsets.zero);

  /// Optional manual insets set by the user via the overlay editor. When
  /// non-null these insets take precedence for the overlay and can be
  /// applied to the native player with [applyManualInsetsToPlayer].
  final ValueNotifier<EdgeInsets?> manualInsetsNotifier = ValueNotifier<EdgeInsets?>(null);

  /// Zoom value that was active before the user entered manual bounds editing.
  /// Restored when manual bounds are cleared so reset can fully undo the edit.
  double? _manualEditPreviousZoomScale;

  /// Vertical pan offset in logical pixels. Positive = shift content down,
  /// negative = shift content up. Allows positioning video at top/center/bottom
  /// within the detected boundaries.
  final ValueNotifier<double> verticalPanOffsetNotifier = ValueNotifier<double>(0.0);

  /// In-progress update loop; concurrent callers mark it dirty and share it.
  Future<void>? _updateLoop;
  bool _updateDirty = false;

  /// Callback invoked when boxFitMode changes, for external persistence
  final void Function(int mode)? onBoxFitModeChanged;

  VideoFilterManager({
    required this.player,
    this.nativeVideoZoom = false,
    int initialBoxFitMode = 0,
    Size? initialPlayerSize,
    this.onBoxFitModeChanged,
  }) : _boxFitMode = initialBoxFitMode,
       _playerSize = initialPlayerSize {
    _debouncedUpdateVideoFilter = debounce(
      updateVideoFilter,
      const Duration(milliseconds: 50),
      leading: true,
      trailing: true,
    );
  }

  /// Current BoxFit mode (0=contain, 1=cover, 2=fill)
  int get boxFitMode => _boxFitMode;

  double get zoomScale => _zoomScale;

  Size? get playerSize => _playerSize;

  static double normalizeZoomScale(double scale) {
    final clamped = scale.clamp(minZoomScale, maxZoomScale).toDouble();
    final percent = (clamped * 100).round();
    if (percent == 100) return 1.0;
    return percent / 100;
  }

  static double videoZoomPropertyForScale(double scale) {
    final normalized = normalizeZoomScale(scale);
    if (normalized == 1.0) return 0.0;
    return math.log(normalized) / math.ln2;
  }

  double setZoomScale(double scale) {
    final next = normalizeZoomScale(scale);
    if (_zoomScale == next) return _zoomScale;
    _zoomScale = next;
    updateVideoFilter();
    return _zoomScale;
  }

  /// Cycle through BoxFit modes: contain → cover → fill → contain (for button)
  void cycleBoxFitMode() {
    _boxFitMode = (_boxFitMode + 1) % 3;
    onBoxFitModeChanged?.call(_boxFitMode);
    updateVideoFilter();
  }

  /// Reset to contain mode (mode 0). Used when enabling ambient lighting.
  void resetToContain() {
    if (_boxFitMode != 0 || (_zoomScale - 1.0).abs() > 0.0001) {
      _boxFitMode = 0;
      _zoomScale = 1.0;
      updateVideoFilter();
    }
  }

  /// Force contain mode for PiP (no cropping/stretching)
  void enterPipMode() {
    // Disable ambient lighting for PiP — it wastes space on blurred borders
    if (ambientLightingService?.isEnabled == true) {
      _prePipAmbientLighting = true;
      ambientLightingService!.disable();
    }
    if (_boxFitMode != 0) {
      _prePipBoxFitMode = _boxFitMode;
      _boxFitMode = 0; // Contain mode
    }
    if ((_zoomScale - 1.0).abs() > 0.0001) {
      _prePipZoomScale = _zoomScale;
      _zoomScale = 1.0;
    }
    if (_prePipBoxFitMode != null || _prePipZoomScale != null) {
      updateVideoFilter();
    }
  }

  /// Restore previous mode when exiting PiP
  void exitPipMode() {
    var shouldUpdate = false;
    if (_prePipBoxFitMode != null) {
      _boxFitMode = _prePipBoxFitMode!;
      _prePipBoxFitMode = null;
      shouldUpdate = true;
    }
    if (_prePipZoomScale != null) {
      _zoomScale = normalizeZoomScale(_prePipZoomScale!);
      _prePipZoomScale = null;
      shouldUpdate = true;
    }
    if (shouldUpdate) updateVideoFilter();
  }

  /// Whether ambient lighting was active before entering PiP
  bool get hadAmbientLightingBeforePip => _prePipAmbientLighting == true;

  void clearPipAmbientLightingFlag() {
    _prePipAmbientLighting = null;
  }

  void updatePlayerSize(Size size) {
    // Check if size actually changed to avoid unnecessary updates
    if (_playerSize == null ||
        (_playerSize!.width - size.width).abs() > 0.1 ||
        (_playerSize!.height - size.height).abs() > 0.1) {
      _playerSize = size;
      debouncedUpdateVideoFilter();
    }
  }

  /// Update the video scaling and positioning based on current display mode.
  /// Writes are diffed against the last applied values and serialized: while a
  /// run is in flight, further calls coalesce into one trailing re-run instead
  /// of interleaving stale writes (pinch zoom calls this per gesture tick).
  /// When ambient lighting is active, video-aspect-override is managed by ambient lighting.
  Future<void> updateVideoFilter() {
    final running = _updateLoop;
    if (running != null) {
      _updateDirty = true;
      return running;
    }
    final loop = _runUpdateLoop();
    _updateLoop = loop;
    return loop;
  }

  Future<void> _runUpdateLoop() async {
    try {
      do {
        _updateDirty = false;
        await _applyVideoFilter();
      } while (_updateDirty);
    } finally {
      _updateLoop = null;
    }
  }

  Future<void> _applyVideoFilter() async {
    try {
      final boxFitMode = _boxFitMode;
      final zoomScale = _zoomScale;
      final playerSize = _playerSize;
      final ambientActive = ambientLightingService?.isEnabled == true;
      final coverMode = boxFitMode == 1;

      // ExoPlayer handles scaling via AspectRatioFrameLayout (no-op on mpv
      // backends). The MPV properties below still run — on ExoPlayer they
      // forward to setMpvProperty, which queues them for any future fallback.
      if (_appliedBoxFitMode != boxFitMode) {
        _appliedBoxFitMode = null;
        await player.setBoxFitMode(boxFitMode);
        _appliedBoxFitMode = boxFitMode;
      }
      if (_appliedVideoZoom != zoomScale) {
        _appliedVideoZoom = null;
        await player.setVideoZoom(zoomScale);
        _appliedVideoZoom = zoomScale;
      }

      // Compute final target values up-front: each mpv write takes effect
      // immediately, so transient intermediate values would flash on screen.
      String? aspectOverride = ambientActive ? null : 'no';
      if (boxFitMode == 2) {
        // Fill/stretch mode - override aspect ratio to match player (stretches video)
        if (playerSize != null && playerSize.width > 0 && playerSize.height > 0) {
          final playerAspect = playerSize.width / playerSize.height;
          if (playerAspect.isFinite && playerAspect > 0) {
            aspectOverride = playerAspect.toString();
            appLogger.d('Stretch mode: aspect-override=$playerAspect (player: $playerSize)');
          }
        }
      }

      if (aspectOverride != null) {
        await _applyProperty('video-aspect-override', aspectOverride);
      }
      if (ambientActive) {
        // Ambient lighting writes video-aspect-override out-of-band, so any
        // cached value is unreliable; forget it so the next run rewrites it.
        _appliedProps.remove('video-aspect-override');
      }
      await _applyProperty('sub-ass-force-margins', coverMode || zoomScale > 1.0001 ? 'yes' : 'no');
      await _applyProperty('panscan', coverMode ? '1.0' : '0');
      await _applyProperty('video-zoom', nativeVideoZoom ? '0.0' : videoZoomPropertyForScale(zoomScale).toString());

      // Update computed content rect and black bar insets for consumers
      await _updateContentRect();
    } catch (e) {
      appLogger.w('Failed to update video filter', error: e);
    }
  }

  Future<void> _updateContentRect() async {
    final playerSize = _playerSize;
    if (playerSize == null || playerSize.width <= 0 || playerSize.height <= 0) return;

    try {
      final wStr = await player.getProperty('video-params/w');
      final hStr = await player.getProperty('video-params/h');
      if (wStr == null || hStr == null) {
        // Unknown video size — assume content fills viewport
        _setContentRect(Rect.fromLTWH(0, 0, playerSize.width, playerSize.height));
        return;
      }

      final vw = int.tryParse(wStr);
      final vh = int.tryParse(hStr);
      if (vw == null || vh == null || vh == 0) {
        _setContentRect(Rect.fromLTWH(0, 0, playerSize.width, playerSize.height));
        return;
      }

      final videoAspect = vw / vh;
      final playerAspect = playerSize.width / playerSize.height;

      double dispW, dispH, left, top;

      // Compute displayed video rectangle according to BoxFit mode.
      if (_boxFitMode == 0) {
        // Contain (letterbox / pillarbox) — video fits entirely inside viewport
        if (playerAspect > videoAspect) {
          dispH = playerSize.height;
          dispW = dispH * videoAspect;
          left = (playerSize.width - dispW) / 2.0;
          top = 0.0;
        } else {
          dispW = playerSize.width;
          dispH = dispW / videoAspect;
          left = 0.0;
          top = (playerSize.height - dispH) / 2.0;
        }
      } else if (_boxFitMode == 1) {
        // Cover (crop to fill) — the visible area is the full viewport but the
        // source may be cropped; report the viewport as content rect to avoid
        // suggesting black bars where none exist.
        left = 0.0;
        top = 0.0;
        dispW = playerSize.width;
        dispH = playerSize.height;
      } else {
        // Fill/stretch — content occupies the full viewport
        left = 0.0;
        top = 0.0;
        dispW = playerSize.width;
        dispH = playerSize.height;
      }

      final rect = Rect.fromLTWH(left.clamp(0.0, playerSize.width), top.clamp(0.0, playerSize.height),
          dispW.clamp(0.0, playerSize.width), dispH.clamp(0.0, playerSize.height));
      _setContentRect(rect);
    } catch (e) {
      appLogger.w('Failed to update content rect', error: e);
    }
  }

  void _setContentRect(Rect rect) {
    contentRectNotifier.value = rect;
    final playerSize = _playerSize!;
    final left = rect.left;
    final top = rect.top;
    final right = (playerSize.width - (rect.left + rect.width)).clamp(0.0, playerSize.width);
    final bottom = (playerSize.height - (rect.top + rect.height)).clamp(0.0, playerSize.height);
    blackBarInsetsNotifier.value = EdgeInsets.fromLTRB(left, top, right, bottom);
  }

  /// Recompute content rect and apply vertical pan offset.
  void _updateContentRectWithPan() {
    final manualInsets = manualInsetsNotifier.value;
    final playerSize = _playerSize;
    if (playerSize == null) return;

    EdgeInsets insets;
    if (manualInsets != null) {
      insets = manualInsets;
    } else {
      insets = blackBarInsetsNotifier.value;
    }

    // Compute the content rect from insets
    final rect = Rect.fromLTWH(
      insets.left.clamp(0.0, playerSize.width),
      insets.top.clamp(0.0, playerSize.height),
      (playerSize.width - insets.left - insets.right).clamp(0.0, playerSize.width),
      (playerSize.height - insets.top - insets.bottom).clamp(0.0, playerSize.height),
    );

    // Apply vertical pan offset
    final panOffset = verticalPanOffsetNotifier.value;
    final panRect = rect.translate(0, panOffset);
    // Clamp to player bounds
    final clampedRect = Rect.fromLTWH(
      panRect.left.clamp(0.0, playerSize.width),
      panRect.top.clamp(0.0, playerSize.height),
      rect.width,
      rect.height,
    );

    contentRectNotifier.value = clampedRect;
    final l = clampedRect.left;
    final t = clampedRect.top;
    final r = (playerSize.width - (clampedRect.left + clampedRect.width)).clamp(0.0, playerSize.width);
    final b = (playerSize.height - (clampedRect.top + clampedRect.height)).clamp(0.0, playerSize.height);
    blackBarInsetsNotifier.value = EdgeInsets.fromLTRB(l, t, r, b);
  }

  /// Set manual insets (logical pixels). Passing null clears manual mode.
  void setManualInsets(EdgeInsets? insets) {
    if (insets != null && manualInsetsNotifier.value == null) {
      _manualEditPreviousZoomScale = _zoomScale;
    }
    manualInsetsNotifier.value = insets;
    // When editing, reflect in the visible overlay immediately.
    if (insets != null) {
      final playerSize = _playerSize;
      if (playerSize != null) {
        final rect = Rect.fromLTWH(
          insets.left.clamp(0.0, playerSize.width),
          insets.top.clamp(0.0, playerSize.height),
          (playerSize.width - insets.left - insets.right).clamp(0.0, playerSize.width),
          (playerSize.height - insets.top - insets.bottom).clamp(0.0, playerSize.height),
        );
        contentRectNotifier.value = rect;
      }
    } else {
      if (_manualEditPreviousZoomScale != null && (_zoomScale - _manualEditPreviousZoomScale!).abs() > 0.0001) {
        _zoomScale = normalizeZoomScale(_manualEditPreviousZoomScale!);
        updateVideoFilter();
      }
      _manualEditPreviousZoomScale = null;
      // Recompute from actual video params on clear
      unawaited(_updateContentRect());
    }
  }

  /// Set vertical pan offset (logical pixels). Pass 0 to center.
  void setVerticalPanOffset(double offsetPx) {
    verticalPanOffsetNotifier.value = offsetPx.clamp(-500.0, 500.0);
    // Reflect in content rect immediately
    _updateContentRectWithPan();
  }

  /// Apply the currently-set manual insets to the player as a best-effort
  /// physical change. The manual bounds define the projection frame; we keep
  /// the video un-cropped and let the surrounding overlay/bounds represent the
  /// target area.
  Future<void> applyManualInsetsToPlayer() async {
    final insets = manualInsetsNotifier.value;
    final playerSize = _playerSize;
    if (insets == null || playerSize == null) return;

    try {
      // Commit the manual projection bounds as the active overlay geometry.
      // This intentionally does not zoom the video; it just makes the chosen
      // rectangle the authoritative "screen area" for the rest of the UI.
      final rect = Rect.fromLTWH(
        insets.left.clamp(0.0, playerSize.width),
        insets.top.clamp(0.0, playerSize.height),
        (playerSize.width - insets.left - insets.right).clamp(0.0, playerSize.width),
        (playerSize.height - insets.top - insets.bottom).clamp(0.0, playerSize.height),
      );
      contentRectNotifier.value = rect;
      blackBarInsetsNotifier.value = EdgeInsets.fromLTRB(rect.left, rect.top, playerSize.width - rect.right, playerSize.height - rect.bottom);
      await updateVideoFilter();
    } catch (e) {
      appLogger.w('Failed to apply manual insets to player', error: e);
    }
  }

  Future<void> _applyProperty(String name, String value) async {
    if (_appliedProps[name] == value) return;
    // Uncache while in flight so a failed write is retried on the next run.
    _appliedProps.remove(name);
    await player.setProperty(name, value);
    _appliedProps[name] = value;
  }

  /// Debounced version of updateVideoFilter for resize events.
  /// Uses leading-edge debounce: first call executes immediately,
  /// subsequent calls within 50ms are debounced.
  void debouncedUpdateVideoFilter() => _debouncedUpdateVideoFilter();

  void dispose() {
    _debouncedUpdateVideoFilter.cancel();
    contentRectNotifier.dispose();
    blackBarInsetsNotifier.dispose();
    manualInsetsNotifier.dispose();
    verticalPanOffsetNotifier.dispose();
  }
}
