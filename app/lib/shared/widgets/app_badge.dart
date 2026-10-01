import 'dart:async';

import 'package:flutter/material.dart';
import 'package:wheres_the_bus/app/theme/app_text_styles.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/shared/motion/app_motion.dart';

enum _BadgeVariant { filled, outlined, dot }

class AppBadge extends StatefulWidget {
  const AppBadge({super.key, this.label, this.color})
    : _variant = label == null ? _BadgeVariant.dot : _BadgeVariant.filled;

  const AppBadge.outlined({super.key, this.label})
    : color = null,
      _variant = _BadgeVariant.outlined;

  final String? label;

  /// Data color for transit line/mode/type pills. When set, the badge renders
  /// as a static r4 pill with contrast-picked text — the app's line-pill
  /// vocabulary — instead of the animated Ink status badge.
  final Color? color;
  final _BadgeVariant _variant;

  @override
  State<AppBadge> createState() => _AppBadgeState();
}

Color _badgeTextColor(Color bg) {
  final l = bg.computeLuminance();
  final whiteContrast = 1.05 / (l + 0.05);
  final blackContrast = (l + 0.05) / 0.05;
  return blackContrast >= whiteContrast ? Colors.black : Colors.white;
}

class _AppBadgeState extends State<AppBadge>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scale;
  late final Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: AppMotion.short,
    );
    _scale = Tween<double>(begin: 0.9, end: 1).animate(
      CurvedAnimation(parent: _controller, curve: AppMotion.easeOut),
    );
    _opacity = CurvedAnimation(parent: _controller, curve: AppMotion.easeOut);
    unawaited(_controller.forward());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    // Data-colored pill: static, r4, contrast text. Distinct shape/behavior
    // from the animated Ink status badge below.
    final dataColor = widget.color;
    if (widget._variant == _BadgeVariant.filled && dataColor != null) {
      return Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppTheme.space8,
          vertical: 3,
        ),
        decoration: BoxDecoration(
          color: dataColor,
          borderRadius: BorderRadius.circular(AppTheme.radiusChip),
        ),
        child: Text(
          widget.label ?? '',
          style: AppTextStyles.bodySmall.copyWith(
            color: _badgeTextColor(dataColor),
            fontWeight: FontWeight.w600,
          ),
        ),
      );
    }

    Widget badge;
    if (widget._variant == _BadgeVariant.dot) {
      badge = Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(color: cs.error, shape: BoxShape.circle),
      );
    } else {
      final isOutlined = widget._variant == _BadgeVariant.outlined;
      badge = Container(
        height: 20,
        padding: const EdgeInsets.symmetric(horizontal: AppTheme.space6),
        decoration: BoxDecoration(
          color: isOutlined ? Colors.transparent : cs.primary,
          borderRadius: BorderRadius.circular(AppTheme.radiusStadium),
          border: isOutlined ? Border.all(color: cs.primary) : null,
        ),
        alignment: Alignment.center,
        child: Text(
          widget.label ?? '',
          style: AppTextStyles.bodySmall.copyWith(
            color: isOutlined ? cs.primary : cs.onPrimary,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
    }

    if (MediaQuery.disableAnimationsOf(context)) {
      return badge;
    }
    return FadeTransition(
      opacity: _opacity,
      child: ScaleTransition(scale: _scale, child: badge),
    );
  }
}
