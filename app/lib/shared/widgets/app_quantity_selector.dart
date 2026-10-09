import 'dart:async';

import 'package:flutter/material.dart';
import 'package:wheres_the_bus/app/theme/app_text_styles.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/shared/motion/app_motion.dart';

class AppQuantitySelector extends StatefulWidget {
  const AppQuantitySelector({
    required this.value,
    required this.onChanged,
    super.key,
    this.min = 0,
    this.max = 99,
  });

  final int value;
  final ValueChanged<int> onChanged;
  final int min;
  final int max;

  @override
  State<AppQuantitySelector> createState() => _AppQuantitySelectorState();
}

class _AppQuantitySelectorState extends State<AppQuantitySelector> {
  int _direction = 0;

  @override
  void didUpdateWidget(AppQuantitySelector old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value) {
      _direction = widget.value > old.value ? 1 : -1;
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      height: 44,
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppTheme.radiusStadium),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _QuantityButton(
            icon: Icons.remove_rounded,
            enabled: widget.value > widget.min,
            onTap: widget.value > widget.min
                ? () => widget.onChanged(widget.value - 1)
                : null,
          ),
          SizedBox(
            width: 32,
            child: _AnimatedValue(
              value: widget.value,
              direction: _direction,
            ),
          ),
          _QuantityButton(
            icon: Icons.add_rounded,
            enabled: widget.value < widget.max,
            onTap: widget.value < widget.max
                ? () => widget.onChanged(widget.value + 1)
                : null,
          ),
        ],
      ),
    );
  }
}

class _AnimatedValue extends StatefulWidget {
  const _AnimatedValue({required this.value, required this.direction});

  final int value;
  final int direction;

  @override
  State<_AnimatedValue> createState() => _AnimatedValueState();
}

class _AnimatedValueState extends State<_AnimatedValue>
    with SingleTickerProviderStateMixin {
  static const _duration = Duration(milliseconds: 100);

  late AnimationController _controller;
  int _displayValue = 0;
  int _pendingDirection = 0;

  @override
  void initState() {
    super.initState();
    _displayValue = widget.value;
    _controller = AnimationController(vsync: this, duration: _duration);
  }

  @override
  void didUpdateWidget(_AnimatedValue old) {
    super.didUpdateWidget(old);
    if (old.value == widget.value) {
      return;
    }
    _pendingDirection = widget.direction;
    if (AppMotion.reduced(context)) {
      _displayValue = widget.value;
      _pendingDirection = 0;
      return;
    }
    if (_controller.status == AnimationStatus.forward) {
      // Already mid-transition to a newer value: let it settle and pick up
      // the latest value on completion instead of restarting the timeline
      // from zero, which would hard-reset the roll on every rapid tap.
      return;
    }
    unawaited(
      _controller.forward(from: 0).then((_) {
        if (mounted) {
          setState(() {
            _displayValue = widget.value;
            _pendingDirection = 0;
          });
          unawaited(_controller.reverse());
        }
      }),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final t = _controller.value;
        final slideOffset = _pendingDirection * 4.0 * t;
        final opacity = (1.0 - t).clamp(0.0, 1.0);
        return Opacity(
          opacity: opacity,
          child: Transform.translate(
            offset: Offset(0, slideOffset),
            child: child,
          ),
        );
      },
      child: Text(
        '$_displayValue',
        textAlign: TextAlign.center,
        style: AppTextStyles.bodyLarge.copyWith(
          fontWeight: FontWeight.w600,
          color: cs.onSurface,
        ),
      ),
    );
  }
}

class _QuantityButton extends StatefulWidget {
  const _QuantityButton({
    required this.icon,
    required this.enabled,
    this.onTap,
  });

  final IconData icon;
  final bool enabled;
  final VoidCallback? onTap;

  @override
  State<_QuantityButton> createState() => _QuantityButtonState();
}

class _QuantityButtonState extends State<_QuantityButton> {
  bool _pressed = false;

  void _onTapDown(TapDownDetails _) {
    if (!widget.enabled) return;
    setState(() => _pressed = true);
  }

  void _onTapUp(TapUpDetails _) {
    setState(() => _pressed = false);
  }

  void _onTapCancel() {
    setState(() => _pressed = false);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final reduceMotion = AppMotion.reduced(context);
    return GestureDetector(
      onTapDown: _onTapDown,
      onTapUp: _onTapUp,
      onTapCancel: _onTapCancel,
      onTap: widget.enabled ? widget.onTap : null,
      child: AnimatedOpacity(
        opacity: widget.enabled ? 1.0 : 0.38,
        duration: reduceMotion
            ? Duration.zero
            : const Duration(milliseconds: 100),
        curve: AppMotion.easeOut,
        child: AnimatedScale(
          scale: _pressed ? 0.90 : 1.0,
          duration: reduceMotion
              ? Duration.zero
              : (_pressed
                    ? const Duration(milliseconds: 100)
                    : const Duration(milliseconds: 80)),
          curve: AppMotion.easeOut,
          child: SizedBox(
            width: 36,
            height: 36,
            child: Icon(
              widget.icon,
              size: 20,
              color: cs.onSurface,
            ),
          ),
        ),
      ),
    );
  }
}
