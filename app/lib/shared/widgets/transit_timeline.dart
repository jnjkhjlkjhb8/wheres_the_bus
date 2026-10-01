/// Shared transit timeline widgets.
library;

import 'package:flutter/material.dart';
import 'package:wheres_the_bus/app/theme/app_text_styles.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';

/// How a stop's node is drawn. The distinctions are informational, not
/// decorative: a terminus ends the line, an emphasised stop is one the rider
/// picked (board / alight / their own stop).
enum TimelineNodeKind { intermediate, terminus, emphasis }

/// Width of the spine gutter. Rows align their text against this, so it is the
/// one number both stop lists share.
const double kTimelineGutter = 32;

/// The spine cell for one row: the line running through it, plus this stop's
/// node. Purely decorative — the row's text carries the semantics.
class TimelineSpine extends StatelessWidget {
  const TimelineSpine({
    required this.kind,
    this.lineAbove = true,
    this.lineBelow = true,
    this.travelledAbove = false,
    this.travelledBelow = false,
    this.dimmed = false,
    super.key,
  });

  final TimelineNodeKind kind;

  /// False at the ends of the list, so the line stops at the first and last
  /// node instead of running off into the padding.
  final bool lineAbove;
  final bool lineBelow;

  /// Whether the vehicle has already covered the segment above / below this
  /// node. Covered track is solid ink, track still ahead is the outline tone —
  /// that contrast is the whole point of drawing the spine.
  final bool travelledAbove;
  final bool travelledBelow;

  /// A stop that is out of service or already passed for good; the node drops
  /// to the outline tone whatever its kind.
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final ahead = AppTheme.inkTertiary(cs.brightness);
    final done = cs.onSurface;

    return ExcludeSemantics(
      child: SizedBox(
        width: kTimelineGutter,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Positioned.fill(
              child: Column(
                children: [
                  Expanded(
                    child: _Segment(
                      color: lineAbove ? (travelledAbove ? done : ahead) : null,
                    ),
                  ),
                  Expanded(
                    child: _Segment(
                      color: lineBelow ? (travelledBelow ? done : ahead) : null,
                    ),
                  ),
                ],
              ),
            ),
            _Node(
              kind: kind,
              filled: travelledAbove && !dimmed,
              dimmed: dimmed,
            ),
          ],
        ),
      ),
    );
  }
}

/// One half of the spine line. A null [color] leaves the gap empty, which is
/// how the line stops at the first and last node.
class _Segment extends StatelessWidget {
  const _Segment({required this.color});

  final Color? color;

  @override
  Widget build(BuildContext context) {
    if (color == null) return const SizedBox.shrink();
    return Center(child: Container(width: 2, color: color));
  }
}

class _Node extends StatelessWidget {
  const _Node({required this.kind, required this.filled, required this.dimmed});

  final TimelineNodeKind kind;
  final bool filled;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final ink = dimmed ? AppTheme.inkTertiary(cs.brightness) : cs.onSurface;

    return switch (kind) {
      // The terminus is a square: it reads as a stop-end rather than as one
      // more dot in the run, without needing a label to say so.
      TimelineNodeKind.terminus => Container(
        width: 11,
        height: 11,
        decoration: BoxDecoration(
          color: ink,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
      // A ring, not a fill: the rider's own stop should read as a marked
      // position on the line rather than as a heavier version of a passed one.
      TimelineNodeKind.emphasis => Container(
        width: 13,
        height: 13,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: cs.surface,
          border: Border.all(color: ink, width: 3),
        ),
      ),
      TimelineNodeKind.intermediate => Container(
        width: 9,
        height: 9,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: filled ? ink : cs.surface,
          border: Border.all(color: filled ? ink : cs.outline, width: 2),
        ),
      ),
    };
  }
}

class TimelineVehicleMarker extends StatelessWidget {
  const TimelineVehicleMarker({
    required this.semanticLabel,
    this.label,
    this.trailing,
    this.trailingIsAlert = false,
    this.badge,
    super.key,
  });

  /// What the marker means, for screen readers only — e.g. '公車在這' /
  /// '列車在此'. Always spoken, because the divider on its own says nothing
  /// out loud even when nothing is printed on it.
  final String semanticLabel;

  final String? label;

  /// Optional right-hand note — a delay, a plate. Null shows nothing.
  final String? trailing;

  /// Renders [trailing] in the delay tone. Off by default so a neutral note
  /// (a plate) does not read as a problem.
  final bool trailingIsAlert;

  final IconData? badge;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Semantics(
      label: [semanticLabel, label, trailing].nonNulls.join('，'),
      excludeSemantics: true,
      child: Row(
        children: [
          SizedBox(
            width: kTimelineGutter,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Positioned.fill(
                  child: Center(
                    child: Container(width: 2, color: cs.onSurface),
                  ),
                ),
                Container(
                  width: 17,
                  height: 17,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: cs.onSurface,
                  ),
                  // Points down the list, the direction the vehicle is
                  // travelling in — the rows below it are the stops still
                  // ahead.
                  child: Icon(
                    Icons.arrow_downward_rounded,
                    size: 11,
                    color: cs.surface,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                0,
                AppTheme.space6,
                AppTheme.space16,
                AppTheme.space6,
              ),
              child: Row(
                children: [
                  if (label != null) ...[
                    Text(
                      label!,
                      style: AppTextStyles.bodyVerySmall.copyWith(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: cs.onSurface,
                      ),
                    ),
                    const SizedBox(width: AppTheme.space8),
                  ],
                  if (badge != null) ...[
                    Icon(badge, size: 16, color: cs.onSurface),
                    const SizedBox(width: AppTheme.space8),
                  ],
                  Expanded(
                    child: Container(
                      height: 1,
                      color: cs.onSurface.withValues(alpha: 0.22),
                    ),
                  ),
                  if (trailing != null) ...[
                    const SizedBox(width: AppTheme.space8),
                    Text(
                      trailing!,
                      style: AppTextStyles.bodyVerySmall.copyWith(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: trailingIsAlert
                            ? AppTheme.trainDelay
                            : cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class TimelineStopTag extends StatelessWidget {
  const TimelineStopTag(this.label, {this.solid = true, super.key});

  final String label;
  final bool solid;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTheme.space6,
        vertical: AppTheme.space2,
      ),
      decoration: BoxDecoration(
        color: solid ? cs.onSurface : Colors.transparent,
        borderRadius: BorderRadius.circular(AppTheme.radiusChip),
        border: solid ? null : Border.all(color: cs.outlineVariant),
      ),
      child: Text(
        label,
        style: AppTextStyles.bodyVerySmall.copyWith(
          fontWeight: FontWeight.w700,
          color: solid ? cs.surface : cs.onSurfaceVariant,
        ),
      ),
    );
  }
}
