import 'package:flutter/material.dart';
import 'package:wheres_the_bus/shared/motion/app_motion.dart';

enum _Variant { filled, outlined, text, destructive }

class AppButton extends StatefulWidget {
  const AppButton({
    required this.label,
    super.key,
    this.icon,
    this.onPressed,
  }) : _variant = _Variant.filled;

  const AppButton.outlined({
    required this.label,
    super.key,
    this.icon,
    this.onPressed,
  }) : _variant = _Variant.outlined;

  const AppButton.text({
    required this.label,
    super.key,
    this.icon,
    this.onPressed,
  }) : _variant = _Variant.text;

  const AppButton.destructive({
    required this.label,
    super.key,
    this.icon,
    this.onPressed,
  }) : _variant = _Variant.destructive;

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final _Variant _variant;

  @override
  State<AppButton> createState() => _AppButtonState();
}

class _AppButtonState extends State<AppButton> {
  bool _pressed = false;

  void _setPressed(bool v) {
    if (_pressed == v || widget.onPressed == null) return;
    setState(() => _pressed = v);
  }

  // AppButton's own AnimatedScale (see build below) is the single feedback
  // system; the Material overlay tint is zeroed out here so it doesn't
  // double up with the scale.
  static const WidgetStateProperty<Color> _noOverlay = WidgetStatePropertyAll(
    Colors.transparent,
  );

  Widget _buildButton(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    switch (widget._variant) {
      case _Variant.filled:
        return widget.icon == null
            ? FilledButton(
                onPressed: widget.onPressed,
                style: const ButtonStyle(overlayColor: _noOverlay),
                child: Text(widget.label),
              )
            : FilledButton.icon(
                onPressed: widget.onPressed,
                style: const ButtonStyle(overlayColor: _noOverlay),
                icon: Icon(widget.icon),
                label: Text(widget.label),
              );
      case _Variant.outlined:
        return widget.icon == null
            ? OutlinedButton(
                onPressed: widget.onPressed,
                style: const ButtonStyle(overlayColor: _noOverlay),
                child: Text(widget.label),
              )
            : OutlinedButton.icon(
                onPressed: widget.onPressed,
                style: const ButtonStyle(overlayColor: _noOverlay),
                icon: Icon(widget.icon),
                label: Text(widget.label),
              );
      case _Variant.text:
        return widget.icon == null
            ? TextButton(
                onPressed: widget.onPressed,
                style: const ButtonStyle(overlayColor: _noOverlay),
                child: Text(widget.label),
              )
            : TextButton.icon(
                onPressed: widget.onPressed,
                style: const ButtonStyle(overlayColor: _noOverlay),
                icon: Icon(widget.icon),
                label: Text(widget.label),
              );
      case _Variant.destructive:
        return widget.icon == null
            ? FilledButton(
                onPressed: widget.onPressed,
                style: FilledButton.styleFrom(
                  backgroundColor: cs.error,
                  foregroundColor: cs.onError,
                  overlayColor: Colors.transparent,
                ),
                child: Text(widget.label),
              )
            : FilledButton.icon(
                onPressed: widget.onPressed,
                style: FilledButton.styleFrom(
                  backgroundColor: cs.error,
                  foregroundColor: cs.onError,
                  overlayColor: Colors.transparent,
                ),
                icon: Icon(widget.icon),
                label: Text(widget.label),
              );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => _setPressed(true),
      onPointerUp: (_) => _setPressed(false),
      onPointerCancel: (_) => _setPressed(false),
      child: AnimatedScale(
        scale: _pressed ? AppMotion.pressedScale : 1.0,
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : AppMotion.press,
        curve: AppMotion.easeOut,
        child: _buildButton(context),
      ),
    );
  }
}
