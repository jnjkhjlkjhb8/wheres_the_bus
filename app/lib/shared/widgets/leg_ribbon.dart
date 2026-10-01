import 'package:flutter/material.dart';
import 'package:wheres_the_bus/app/theme/app_text_styles.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';

class LegRibbonSegment {
  const LegRibbonSegment({
    required this.icon,
    required this.minutes,
    this.color,
  });

  final Widget icon;
  final String minutes;
  final Color? color;
}

class LegRibbon extends StatelessWidget {
  const LegRibbon({required this.segments, super.key});

  final List<LegRibbonSegment> segments;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: AppTheme.space4,
      runSpacing: AppTheme.space4,
      children: [
        for (final (i, s) in segments.indexed) ...[
          _Leg(segment: s),
          if (i < segments.length - 1)
            Container(
              width: 12,
              height: 3,
              decoration: BoxDecoration(
                color: s.color ?? cs.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
        ],
      ],
    );
  }
}

class _Leg extends StatelessWidget {
  const _Leg({required this.segment});
  final LegRibbonSegment segment;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        segment.icon,
        const SizedBox(width: 3),
        Text(
          segment.minutes,
          style: AppTextStyles.bodySmall.copyWith(
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}
