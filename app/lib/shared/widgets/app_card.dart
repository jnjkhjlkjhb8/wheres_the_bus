import 'package:flutter/material.dart';
import 'package:wheres_the_bus/app/theme/app_shadows.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';

enum _CardVariant { elevated, filled, outlined }

class AppCard extends StatelessWidget {
  const AppCard({required this.child, super.key, this.padding})
    : _variant = _CardVariant.elevated;
  const AppCard.filled({required this.child, super.key, this.padding})
    : _variant = _CardVariant.filled;
  const AppCard.outlined({required this.child, super.key, this.padding})
    : _variant = _CardVariant.outlined;

  final Widget child;
  final EdgeInsetsGeometry? padding;
  final _CardVariant _variant;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    Color bg;
    List<BoxShadow> shadows;
    Border? border;

    switch (_variant) {
      // Card surface, never the scaffold's own colour — otherwise the card only
      // shows where its shadow lands, and in dark mode not at all.
      case _CardVariant.elevated:
        bg = cs.surfaceContainerLow;
        shadows = AppShadows.cardFor(cs.brightness);
        border = null;
      case _CardVariant.filled:
        bg = cs.surfaceContainerHighest;
        shadows = [];
        border = null;
      case _CardVariant.outlined:
        bg = cs.surfaceContainerLow;
        shadows = [];
        border = Border.all(color: cs.outlineVariant);
    }

    return Container(
      width: double.infinity,
      padding: padding ?? const EdgeInsets.all(AppTheme.space16),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(AppTheme.radiusCard),
        boxShadow: shadows,
        border: border,
      ),
      child: child,
    );
  }
}
