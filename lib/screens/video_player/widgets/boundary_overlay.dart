import 'package:flutter/material.dart';

import '../../../services/video_filter_manager.dart';

/// Non-interactive overlay that visualizes detected video content bounds and
/// black bars reported by [VideoFilterManager]. Designed to sit directly on
/// top of the player's viewport (same logical pixels).
class BoundaryOverlay extends StatelessWidget {
  final VideoFilterManager manager;
  final Color barColor;
  final Color strokeColor;

  const BoundaryOverlay({super.key, required this.manager, this.barColor = const Color(0x77000000), this.strokeColor = const Color(0xFFFFFFFF)});

  @override
  Widget build(BuildContext context) {
    // Use manual insets when present (editing), otherwise show detected bars
    return ValueListenableBuilder<EdgeInsets?>(
      valueListenable: manager.manualInsetsNotifier,
      builder: (context, manual, _) {
        final baseInsets = manager.blackBarInsetsNotifier.value;
        final insets = manual ?? baseInsets;
        final playerSize = manager.playerSize ?? Size.zero;

        return Stack(
          fit: StackFit.passthrough,
          children: [
            if (insets.top > 0)
              Positioned(left: 0, top: 0, right: 0, height: insets.top, child: Container(color: barColor)),
            if (insets.bottom > 0)
              Positioned(left: 0, bottom: 0, right: 0, height: insets.bottom, child: Container(color: barColor)),
            if (insets.left > 0)
              Positioned(left: 0, top: insets.top, bottom: insets.bottom, width: insets.left, child: Container(color: barColor)),
            if (insets.right > 0)
              Positioned(right: 0, top: insets.top, bottom: insets.bottom, width: insets.right, child: Container(color: barColor)),

            // Content rect stroke
            ValueListenableBuilder<Rect?>(
              valueListenable: manager.contentRectNotifier,
              builder: (context, rect, _) {
                if (rect == null) return const SizedBox.shrink();
                return Positioned(
                  left: rect.left,
                  top: rect.top,
                  width: rect.width,
                  height: rect.height,
                  child: IgnorePointer(
                    child: Container(
                      decoration: BoxDecoration(border: Border.all(color: strokeColor.withValues(alpha: 0.9), width: 1.0)),
                    ),
                  ),
                );
              },
            ),

            // Edge handles for interactive adjustment
            // Top handle
            if (playerSize.height > 0)
              Positioned(
                left: insets.left,
                right: insets.right,
                top: insets.top - 12,
                height: 24,
                child: _EdgeHandle(
                  axis: Axis.vertical,
                  onDrag: (delta) {
                    final newTop = (insets.top + delta).clamp(0.0, playerSize.height - insets.bottom - 1.0);
                    manager.setManualInsets(EdgeInsets.fromLTRB(insets.left, newTop, insets.right, insets.bottom));
                  },
                ),
              ),
            // Bottom handle
            if (playerSize.height > 0)
              Positioned(
                left: insets.left,
                right: insets.right,
                bottom: insets.bottom - 12,
                height: 24,
                child: _EdgeHandle(
                  axis: Axis.vertical,
                  onDrag: (delta) {
                    final newBottom = (insets.bottom - delta).clamp(0.0, playerSize.height - insets.top - 1.0);
                    manager.setManualInsets(EdgeInsets.fromLTRB(insets.left, insets.top, insets.right, newBottom));
                  },
                ),
              ),
            // Left handle
            if (playerSize.width > 0)
              Positioned(
                left: insets.left - 12,
                top: insets.top,
                bottom: insets.bottom,
                width: 24,
                child: _EdgeHandle(
                  axis: Axis.horizontal,
                  onDrag: (delta) {
                    final newLeft = (insets.left + delta).clamp(0.0, playerSize.width - insets.right - 1.0);
                    manager.setManualInsets(EdgeInsets.fromLTRB(newLeft, insets.top, insets.right, insets.bottom));
                  },
                ),
              ),
            // Right handle
            if (playerSize.width > 0)
              Positioned(
                right: insets.right - 12,
                top: insets.top,
                bottom: insets.bottom,
                width: 24,
                child: _EdgeHandle(
                  axis: Axis.horizontal,
                  onDrag: (delta) {
                    final newRight = (insets.right - delta).clamp(0.0, playerSize.width - insets.left - 1.0);
                    manager.setManualInsets(EdgeInsets.fromLTRB(insets.left, insets.top, newRight, insets.bottom));
                  },
                ),
              ),

            // Vertical pan controls (up/down arrows on the right side)
            Positioned(
              right: 16,
              top: playerSize.height / 2 - 50,
              child: ValueListenableBuilder<double>(
                valueListenable: manager.verticalPanOffsetNotifier,
                builder: (context, panOffset, _) {
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Up arrow button
                      GestureDetector(
                        onTap: () => manager.setVerticalPanOffset(panOffset - 10),
                        child: Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(color: Colors.white.withOpacity(0.7), borderRadius: BorderRadius.circular(4)),
                          child: const Icon(Icons.arrow_upward, color: Colors.black, size: 20),
                        ),
                      ),
                      const SizedBox(height: 8),
                      // Pan value display
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(4)),
                        child: Text(
                          panOffset.toStringAsFixed(0),
                          style: const TextStyle(color: Colors.white, fontSize: 12),
                        ),
                      ),
                      const SizedBox(height: 8),
                      // Down arrow button
                      GestureDetector(
                        onTap: () => manager.setVerticalPanOffset(panOffset + 10),
                        child: Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(color: Colors.white.withOpacity(0.7), borderRadius: BorderRadius.circular(4)),
                          child: const Icon(Icons.arrow_downward, color: Colors.black, size: 20),
                        ),
                      ),
                      const SizedBox(height: 8),
                      // Reset to center button
                      GestureDetector(
                        onTap: () => manager.setVerticalPanOffset(0),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                          decoration: BoxDecoration(color: Colors.orange.withOpacity(0.8), borderRadius: BorderRadius.circular(4)),
                          child: const Text(
                            'C',
                            style: TextStyle(color: Colors.black, fontSize: 12, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Small transparent handle used to drag an edge. Deltas are in logical
/// pixels and signed so callers can update insets directly.
class _EdgeHandle extends StatelessWidget {
  final Axis axis;
  final void Function(double delta) onDrag;
  const _EdgeHandle({required this.axis, required this.onDrag});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanUpdate: (details) {
        onDrag(axis == Axis.vertical ? details.delta.dy : details.delta.dx);
      },
      child: Center(
        child: Container(
          width: axis == Axis.horizontal ? 6 : double.infinity,
          height: axis == Axis.vertical ? 6 : double.infinity,
          decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(3.0)),
        ),
      ),
    );
  }
}
