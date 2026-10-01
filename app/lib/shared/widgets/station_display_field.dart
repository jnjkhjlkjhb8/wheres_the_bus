import 'package:flutter/material.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/shared/motion/app_motion.dart';
import 'package:wheres_the_bus/shared/motion/pressable.dart';

class StationDisplayField extends StatelessWidget {
  const StationDisplayField({
    required this.value,
    required this.active,
    super.key,
    this.onTap,
    this.width = 90,
    this.height = 76,
  });

  final String value;
  final bool active;
  final VoidCallback? onTap;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final duration = AppMotion.reduced(context)
        ? Duration.zero
        : AppMotion.short;

    final field = AnimatedContainer(
      duration: duration,
      curve: AppMotion.easeOut,
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: active ? cs.primary : cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      alignment: Alignment.center,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppTheme.space10),
          child: AnimatedDefaultTextStyle(
            duration: duration,
            curve: AppMotion.easeOut,
            style: TextStyle(
              fontFamily: 'IBMPlexSans',
              fontSize: 32,
              fontWeight: FontWeight.w500,
              color: active ? cs.onPrimary : cs.onSurface,
            ),
            child: Text(value),
          ),
        ),
      ),
    );

    if (onTap == null) return field;
    return Pressable(onTap: onTap, semanticLabel: value, child: field);
  }
}
