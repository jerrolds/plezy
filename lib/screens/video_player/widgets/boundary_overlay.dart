import 'package:flutter/material.dart';

import '../../../services/video_filter_manager.dart';

/// Non-interactive overlay that visualizes detected video content bounds and
/// black bars reported by [VideoFilterManager]. Designed to sit directly on
/// top of the player's viewport (same logical pixels).
class BoundaryOverlay extends StatefulWidget {
  final VideoFilterManager manager;
  final Color barColor;
  final Color strokeColor;
  final VoidCallback? onApply;

  const BoundaryOverlay({
    super.key,
    required this.manager,
    this.barColor = const Color(0x77000000),
    this.strokeColor = const Color(0xFFFFFFFF),
    this.onApply,
  });

  @override
  State<BoundaryOverlay> createState() => _BoundaryOverlayState();
}

class _BoundaryOverlayState extends State<BoundaryOverlay> {
  late final TextEditingController _topController;
  late final TextEditingController _bottomController;
  late final TextEditingController _leftController;
  late final TextEditingController _rightController;
  EdgeInsets? _lastManualInsets;
  Offset? _dragStartLocalPosition;
  EdgeInsets? _dragStartInsets;

  @override
  void initState() {
    super.initState();
    _topController = TextEditingController();
    _bottomController = TextEditingController();
    _leftController = TextEditingController();
    _rightController = TextEditingController();
  }

  @override
  void dispose() {
    _topController.dispose();
    _bottomController.dispose();
    _leftController.dispose();
    _rightController.dispose();
    super.dispose();
  }

  void _syncControllers(EdgeInsets insets, Size playerSize) {
    final next = insets;
    if (_lastManualInsets == next) return;
    _lastManualInsets = next;
    _topController.text = _percent(next.top, playerSize.height);
    _bottomController.text = _percent(next.bottom, playerSize.height);
    _leftController.text = _percent(next.left, playerSize.width);
    _rightController.text = _percent(next.right, playerSize.width);
  }

  String _percent(double pixels, double total) {
    if (total <= 0) return '0';
    return ((pixels / total) * 100).round().toString();
  }

  double _parsePercent(String text, double total) {
    final value = double.tryParse(text.trim());
    if (value == null || total <= 0) return 0;
    return (total * value / 100).clamp(0.0, total);
  }

  void _commitInsets({
    required EdgeInsets current,
    required Size playerSize,
    double? top,
    double? bottom,
    double? left,
    double? right,
  }) {
    final next = EdgeInsets.fromLTRB(
      left ?? current.left,
      top ?? current.top,
      right ?? current.right,
      bottom ?? current.bottom,
    );
    widget.manager.setManualInsets(next);
  }

  void _beginDrag(DragStartDetails details, EdgeInsets insets) {
    _dragStartLocalPosition = details.localPosition;
    _dragStartInsets = insets;
  }

  void _updateDrag(DragUpdateDetails details, Size playerSize) {
    final startPos = _dragStartLocalPosition;
    final startInsets = _dragStartInsets;
    if (startPos == null || startInsets == null) return;
    final dx = details.localPosition.dx - startPos.dx;
    final dy = details.localPosition.dy - startPos.dy;

    final nextLeft = (startInsets.left + dx).clamp(0.0, playerSize.width);
    final nextTop = (startInsets.top + dy).clamp(0.0, playerSize.height);
    final nextRight = (playerSize.width - (playerSize.width - startInsets.right - dx)).clamp(0.0, playerSize.width);
    final nextBottom = (playerSize.height - (playerSize.height - startInsets.bottom - dy)).clamp(0.0, playerSize.height);

    final maxLeft = (playerSize.width - nextRight - 1.0).clamp(0.0, playerSize.width);
    final maxTop = (playerSize.height - nextBottom - 1.0).clamp(0.0, playerSize.height);
    final left = nextLeft.clamp(0.0, maxLeft);
    final top = nextTop.clamp(0.0, maxTop);
    final right = (playerSize.width - (playerSize.width - startInsets.right - dx)).clamp(0.0, playerSize.width);
    final bottom = (playerSize.height - (playerSize.height - startInsets.bottom - dy)).clamp(0.0, playerSize.height);

    widget.manager.setManualInsets(EdgeInsets.fromLTRB(left, top, right, bottom));
  }

  @override
  Widget build(BuildContext context) {
    // Use manual insets when present (editing), otherwise show detected bars
    return ValueListenableBuilder<EdgeInsets?>(
      valueListenable: widget.manager.manualInsetsNotifier,
      builder: (context, manual, _) {
        final baseInsets = widget.manager.blackBarInsetsNotifier.value;
        final insets = manual ?? baseInsets;
        final playerSize = widget.manager.playerSize ?? Size.zero;
        _syncControllers(insets, playerSize);

        return Stack(
          fit: StackFit.passthrough,
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onPanStart: (details) => _beginDrag(details, insets),
                onPanUpdate: (details) => _updateDrag(details, playerSize),
                onPanEnd: (_) {
                  _dragStartLocalPosition = null;
                  _dragStartInsets = null;
                },
              ),
            ),
            if (insets.top > 0)
              Positioned(left: 0, top: 0, right: 0, height: insets.top, child: Container(color: widget.barColor)),
            if (insets.bottom > 0)
              Positioned(left: 0, bottom: 0, right: 0, height: insets.bottom, child: Container(color: widget.barColor)),
            if (insets.left > 0)
              Positioned(left: 0, top: insets.top, bottom: insets.bottom, width: insets.left, child: Container(color: widget.barColor)),
            if (insets.right > 0)
              Positioned(right: 0, top: insets.top, bottom: insets.bottom, width: insets.right, child: Container(color: widget.barColor)),

            // Content rect stroke
            ValueListenableBuilder<Rect?>(
              valueListenable: widget.manager.contentRectNotifier,
              builder: (context, rect, _) {
                if (rect == null) return const SizedBox.shrink();
                return Positioned(
                  left: rect.left,
                  top: rect.top,
                  width: rect.width,
                  height: rect.height,
                  child: IgnorePointer(
                    child: Container(
                      decoration: BoxDecoration(border: Border.all(color: widget.strokeColor.withValues(alpha: 0.9), width: 1.0)),
                    ),
                  ),
                );
              },
            ),

            // Edge handles for interactive adjustment
            if (playerSize.height > 0)
              Positioned(
                left: insets.left + 12,
                right: insets.right + 12,
                top: (insets.top - 21).clamp(0.0, playerSize.height),
                child: Center(
                  child: _DragArrow(
                    axis: Axis.vertical,
                    icon: Icons.keyboard_arrow_up_rounded,
                    onDrag: (delta) {
                      final newTop = (insets.top + delta).clamp(0.0, playerSize.height - insets.bottom - 1.0);
                      _commitInsets(current: insets, playerSize: playerSize, top: newTop);
                    },
                  ),
                ),
              ),
            if (playerSize.height > 0)
              Positioned(
                left: insets.left + 12,
                right: insets.right + 12,
                bottom: (insets.bottom - 21).clamp(0.0, playerSize.height),
                child: Center(
                  child: _DragArrow(
                    axis: Axis.vertical,
                    icon: Icons.keyboard_arrow_down_rounded,
                    onDrag: (delta) {
                      final newBottom = (insets.bottom - delta).clamp(0.0, playerSize.height - insets.top - 1.0);
                      _commitInsets(current: insets, playerSize: playerSize, bottom: newBottom);
                    },
                  ),
                ),
              ),
            if (playerSize.width > 0)
              Positioned(
                left: (insets.left - 21).clamp(0.0, playerSize.width),
                top: insets.top + 12,
                bottom: insets.bottom + 12,
                child: Center(
                  child: _DragArrow(
                    axis: Axis.horizontal,
                    icon: Icons.keyboard_arrow_left_rounded,
                    onDrag: (delta) {
                      final newLeft = (insets.left + delta).clamp(0.0, playerSize.width - insets.right - 1.0);
                      _commitInsets(current: insets, playerSize: playerSize, left: newLeft);
                    },
                  ),
                ),
              ),
            if (playerSize.width > 0)
              Positioned(
                right: (insets.right - 21).clamp(0.0, playerSize.width),
                top: insets.top + 12,
                bottom: insets.bottom + 12,
                child: Center(
                  child: _DragArrow(
                    axis: Axis.horizontal,
                    icon: Icons.keyboard_arrow_right_rounded,
                    onDrag: (delta) {
                      final newRight = (insets.right - delta).clamp(0.0, playerSize.width - insets.left - 1.0);
                      _commitInsets(current: insets, playerSize: playerSize, right: newRight);
                    },
                  ),
                ),
              ),

            Positioned(
              left: 16,
              top: 16,
              child: _InsetEditorPanel(
                playerSize: playerSize,
                insets: insets,
                topController: _topController,
                bottomController: _bottomController,
                leftController: _leftController,
                rightController: _rightController,
                onTopSubmitted: (text) => _commitInsets(
                  current: insets,
                  playerSize: playerSize,
                  top: _parsePercent(text, playerSize.height),
                ),
                onBottomSubmitted: (text) => _commitInsets(
                  current: insets,
                  playerSize: playerSize,
                  bottom: _parsePercent(text, playerSize.height),
                ),
                onLeftSubmitted: (text) => _commitInsets(
                  current: insets,
                  playerSize: playerSize,
                  left: _parsePercent(text, playerSize.width),
                ),
                onRightSubmitted: (text) => _commitInsets(
                  current: insets,
                  playerSize: playerSize,
                  right: _parsePercent(text, playerSize.width),
                ),
                onReset: () {
                  widget.manager.setManualInsets(null);
                  widget.manager.setVerticalPanOffset(0);
                },
                onApply: () async {
                  await widget.manager.applyManualInsetsToPlayer();
                  widget.onApply?.call();
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

class _InsetEditorPanel extends StatelessWidget {
  final Size playerSize;
  final EdgeInsets insets;
  final TextEditingController topController;
  final TextEditingController bottomController;
  final TextEditingController leftController;
  final TextEditingController rightController;
  final void Function(String) onTopSubmitted;
  final void Function(String) onBottomSubmitted;
  final void Function(String) onLeftSubmitted;
  final void Function(String) onRightSubmitted;
  final VoidCallback onReset;
  final VoidCallback onApply;

  const _InsetEditorPanel({
    required this.playerSize,
    required this.insets,
    required this.topController,
    required this.bottomController,
    required this.leftController,
    required this.rightController,
    required this.onTopSubmitted,
    required this.onBottomSubmitted,
    required this.onLeftSubmitted,
    required this.onRightSubmitted,
    required this.onReset,
    required this.onApply,
  });

  @override
  Widget build(BuildContext context) {
    if (playerSize.width <= 0 || playerSize.height <= 0) return const SizedBox.shrink();
    return Container(
      width: 220,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(10)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Bounds %', style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(child: _InsetField(label: 'Top', controller: topController, onSubmitted: onTopSubmitted)),
              const SizedBox(width: 8),
              Expanded(child: _InsetField(label: 'Bottom', controller: bottomController, onSubmitted: onBottomSubmitted)),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(child: _InsetField(label: 'Left', controller: leftController, onSubmitted: onLeftSubmitted)),
              const SizedBox(width: 8),
              Expanded(child: _InsetField(label: 'Right', controller: rightController, onSubmitted: onRightSubmitted)),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextButton(
                  onPressed: onReset,
                  style: TextButton.styleFrom(foregroundColor: Colors.white, backgroundColor: Colors.white12),
                  child: const Text('Reset'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton(
                  onPressed: onApply,
                  child: const Text('Apply'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _InsetField extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final void Function(String) onSubmitted;

  const _InsetField({required this.label, required this.controller, required this.onSubmitted});

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      keyboardType: TextInputType.number,
      textInputAction: TextInputAction.done,
      style: const TextStyle(color: Colors.white, fontSize: 12),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: Colors.white70, fontSize: 11),
        isDense: true,
        filled: true,
        fillColor: Colors.white10,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
      ),
      onSubmitted: onSubmitted,
    );
  }
}

class _DragArrow extends StatelessWidget {
  final Axis axis;
  final IconData icon;
  final void Function(double delta) onDrag;
  const _DragArrow({required this.axis, required this.icon, required this.onDrag});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanUpdate: (details) {
        onDrag(axis == Axis.vertical ? details.delta.dy : details.delta.dx);
      },
      child: Center(
        child: Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.18),
            borderRadius: BorderRadius.circular(21),
            border: Border.all(color: Colors.white70, width: 1),
            boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 3, offset: Offset(0, 1))],
          ),
          child: Icon(icon, color: Colors.white, size: 24),
        ),
      ),
    );
  }
}
