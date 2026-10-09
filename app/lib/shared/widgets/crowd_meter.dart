import 'package:flutter/material.dart';

import 'package:wheres_the_bus/data/models/bus_models.dart';

class CrowdMeter extends StatelessWidget {
  const CrowdMeter({required this.level, super.key});

  final CrowdLevel level;

  /// Segment heights in logical pixels, ascending. Scaled by the text scale so
  /// the meter keeps its proportion to the row it annotates under Dynamic Type.
  static const List<double> _heights = [5, 8, 11];
  static const double _barWidth = 3;
  static const double _gap = 2;

  /// How many segments a level fills. Unknown fills none — and is never drawn
  /// (see [build]), because an empty meter reads as an empty bus.
  static int filledFor(CrowdLevel level) => switch (level) {
    CrowdLevel.comfortable => 1,
    CrowdLevel.normal => 2,
    CrowdLevel.crowded => 3,
    CrowdLevel.unknown => 0,
  };

  /// The screen-reader label. The meter is a graphic, so the reading has to
  /// exist as words for anyone not looking at it.
  static String? semanticsLabelFor(CrowdLevel level) => switch (level) {
    CrowdLevel.comfortable => '車上舒適',
    CrowdLevel.normal => '車上一般',
    CrowdLevel.crowded => '車上擁擠',
    CrowdLevel.unknown => null,
  };

  @override
  Widget build(BuildContext context) {
    final filled = filledFor(level);
    if (filled == 0) {
      return const SizedBox.shrink();
    }
    final scheme = Theme.of(context).colorScheme;
    // Full ink only at 擁擠; the quieter two stay in secondary ink.
    final fillColor = level == CrowdLevel.crowded
        ? scheme.onSurface
        : scheme.onSurfaceVariant;
    final emptyColor = scheme.outline;
    final scale =
        MediaQuery.textScalerOf(context).scale(_heights.last) / _heights.last;

    return Semantics(
      label: semanticsLabelFor(level),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (var i = 0; i < _heights.length; i++) ...[
            if (i > 0) SizedBox(width: _gap * scale),
            Container(
              width: _barWidth * scale,
              height: _heights[i] * scale,
              decoration: BoxDecoration(
                color: i < filled ? fillColor : emptyColor,
                borderRadius: BorderRadius.circular(1 * scale),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
