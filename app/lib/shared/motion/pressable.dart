import 'package:flutter/material.dart';
import 'package:wheres_the_bus/shared/motion/app_motion.dart';

/// Adds small press-scale feedback to an interactive child.
class Pressable extends StatefulWidget {
  const Pressable({
    required this.child,
    super.key,
    this.onTap,
    this.onLongPress,
    this.enabled = true,
    this.semanticLabel,
    this.minTapSize,
  });

  final Widget child;

  final VoidCallback? onTap;

  final VoidCallback? onLongPress;

  /// Whether interactions and press feedback are enabled.
  final bool enabled;

  /// Optional semantic label for assistive technologies.
  final String? semanticLabel;

  final double? minTapSize;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed == value) {
      return;
    }
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final onTap = widget.enabled ? widget.onTap : null;
    final onLongPress = widget.enabled ? widget.onLongPress : null;
    final isInteractive = onTap != null || onLongPress != null;
    final minTapSize = widget.minTapSize;
    // Expand only the box the gesture detector sits in; the child paints at its
    // own size, centred, so raising the hit area never changes the visuals.
    final hitTarget = minTapSize == null
        ? widget.child
        : Center(
            widthFactor: 1,
            heightFactor: 1,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minWidth: minTapSize,
                minHeight: minTapSize,
              ),
              child: Center(
                widthFactor: 1,
                heightFactor: 1,
                child: widget.child,
              ),
            ),
          );

    return Semantics(
      label: widget.semanticLabel,
      button: widget.onTap != null,
      enabled: widget.enabled,
      child: AnimatedScale(
        scale: widget.enabled && _pressed ? AppMotion.pressedScale : 1,
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : AppMotion.press,
        curve: AppMotion.easeOut,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: isInteractive ? (_) => _setPressed(true) : null,
          onTapCancel: isInteractive ? () => _setPressed(false) : null,
          onTapUp: isInteractive ? (_) => _setPressed(false) : null,
          onTap: onTap == null
              ? null
              : () {
                  _setPressed(false);
                  onTap();
                },
          onLongPress: onLongPress == null
              ? null
              : () {
                  _setPressed(false);
                  onLongPress();
                },
          child: hitTarget,
        ),
      ),
    );
  }
}
