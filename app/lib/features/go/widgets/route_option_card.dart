import 'package:flutter/material.dart';
import 'package:wheres_the_bus/app/theme/app_text_styles.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/data/models/plan_models.dart';
import 'package:wheres_the_bus/features/go/widgets/transit_visuals.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/motion/app_motion.dart';
import 'package:wheres_the_bus/shared/motion/pressable.dart';

String formatClock(String raw) {
  if (raw.isEmpty) return '';
  final t = raw.contains('T') ? raw.split('T').last : raw;
  final match = RegExp(r'(\d{1,2}:\d{2})').firstMatch(t);
  return match?.group(1) ?? t;
}

int routeMinutes(PlanRoute route) {
  final value = route.travelTime;
  final minutes = value > 600 ? (value / 60).round() : value;
  return minutes.clamp(0, 999);
}

int walkMinutes(PlanRoute route) {
  var total = 0;
  for (final s in route.sections) {
    if (isWalk(s)) total += sectionMinutes(s);
  }
  return total;
}

int waitMinutesBefore(List<PlanSection> sections, int i) {
  if (i <= 0 || i >= sections.length) return 0;
  final arrival = DateTime.tryParse(sections[i - 1].arrival.time);
  final departure = DateTime.tryParse(sections[i].departure.time);
  if (arrival == null || departure == null) return 0;
  final seconds = departure.difference(arrival).inSeconds;
  return seconds <= 0 ? 0 : (seconds / 60).round();
}

/// Total scheduled waiting across all of a route's transfers.
int waitMinutes(PlanRoute route) {
  var total = 0;
  for (var i = 1; i < route.sections.length; i++) {
    total += waitMinutesBefore(route.sections, i);
  }
  return total;
}

class RouteOptionCard extends StatelessWidget {
  const RouteOptionCard({
    required this.route,
    required this.highlighted,
    required this.onTap,
    this.isSaved = false,
    this.onToggleSave,
    super.key,
  });

  final PlanRoute route;
  final bool highlighted;
  final VoidCallback onTap;

  /// Whether this route is currently in the saved snapshots.
  final bool isSaved;

  /// Tapping the bookmark toggles save state; hidden when null.
  final VoidCallback? onToggleSave;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final minutes = routeMinutes(route);
    final departure = formatClock(route.startTime);
    final arrival = formatClock(route.endTime);
    final sections = route.sections;
    final origin = sections.isNotEmpty ? sections.first.departure.name : '';
    final dest = sections.isNotEmpty ? sections.last.arrival.name : '';

    final header = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Expanded, not Flexible: the left column claims the full width so the
        // fare is pinned to the right edge instead of hugging the times.
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    '$minutes',
                    style: AppTextStyles.timeValue(
                      size: AppTextStyles.heading1.fontSize,
                      weight: AppTextStyles.heading1.fontWeight,
                      color: cs.onSurface,
                    ),
                  ),
                  const SizedBox(width: 3),
                  Text(
                    AppI18n.of(context).goMinutesUnit,
                    style: AppTextStyles.bodySmall.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              _DepartArriveWindow(departure: departure, arrival: arrival),
            ],
          ),
        ),
        if (route.totalFare > 0)
          Padding(
            padding: const EdgeInsets.only(
              left: AppTheme.space8,
              top: AppTheme.space2,
            ),
            child: _Fare(amount: route.totalFare),
          ),
      ],
    );

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        header,
        const SizedBox(height: AppTheme.space10),
        LegStrip(sections: sections),
        if (highlighted && (origin.isNotEmpty || dest.isNotEmpty)) ...[
          const SizedBox(height: AppTheme.space8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Flexible(
                child: Text(
                  origin,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.bodySmall.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(width: AppTheme.space12),
              Flexible(
                child: Text(
                  dest,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.end,
                  style: AppTextStyles.bodySmall.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: AppTheme.space10),
        Row(
          children: [
            Icon(
              Icons.swap_horiz_rounded,
              size: 14,
              color: cs.onSurfaceVariant,
            ),
            const SizedBox(width: AppTheme.space4),
            Text(
              route.transfers == 0
                  ? AppI18n.of(context).goDirect
                  : AppI18n.of(context).transfersCount(route.transfers),
              style: AppTextStyles.bodySmall.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
            if (onToggleSave != null) ...[
              const Spacer(),
              _SaveButton(saved: isSaved, onTap: onToggleSave!),
            ],
          ],
        ),
      ],
    );

    return Pressable(
      onTap: onTap,
      semanticLabel: AppI18n.of(
        context,
      ).routeSummarySemantics(minutes, arrival, dest),
      child: Container(
        padding: const EdgeInsets.all(AppTheme.space14),
        decoration: BoxDecoration(
          color: highlighted ? cs.primaryContainer : cs.surface,
          borderRadius: BorderRadius.circular(AppTheme.radiusCard),
          border: highlighted ? null : Border.all(color: cs.outlineVariant),
        ),
        child: content,
      ),
    );
  }
}

class _SaveButton extends StatelessWidget {
  const _SaveButton({required this.saved, required this.onTap});

  final bool saved;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Pressable(
      onTap: onTap,
      semanticLabel: saved
          ? AppI18n.of(context).goUnsaveRoute
          : AppI18n.of(context).goSaveRoute,
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.space2),
        child: AnimatedSwitcher(
          duration: AppMotion.short,
          child: Icon(
            saved ? Icons.bookmark_rounded : Icons.bookmark_border_rounded,
            key: ValueKey(saved),
            size: 20,
            // Saved: solid Ink black. Unsaved: hollow, muted outline.
            color: saved ? cs.onSurface : cs.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

class LegStrip extends StatelessWidget {
  const LegStrip({required this.sections, super.key});

  final List<PlanSection> sections;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final i18n = AppI18n.of(context);
    final children = <Widget>[];

    void chevron() => children.add(
      Icon(Icons.chevron_right_rounded, size: 15, color: cs.outline),
    );

    for (final (i, s) in sections.indexed) {
      final wait = waitMinutesBefore(sections, i);
      if (wait > 0) {
        children.add(
          _GapChip(
            icon: Icons.schedule_rounded,
            minutes: wait,
            semanticLabel: i18n.goWaitMinutes(wait),
          ),
        );
        chevron();
      }
      if (isWalk(s)) {
        final minutes = sectionMinutes(s);
        children.add(
          _GapChip(
            icon: Icons.directions_walk_rounded,
            minutes: minutes,
            semanticLabel: i18n.goWalkLegSemantics(minutes),
          ),
        );
      } else {
        children.add(
          _LegPill(
            icon: transitIcon(s.transport.mode),
            label: sectionLabel(i18n, s),
            minutes: sectionMinutes(s),
            lineColor: transitColor(s.transport, cs),
          ),
        );
      }
      if (i < sections.length - 1) chevron();
    }
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: AppTheme.space4,
      runSpacing: AppTheme.space6,
      children: children,
    );
  }
}

class _GapChip extends StatelessWidget {
  const _GapChip({
    required this.icon,
    required this.minutes,
    required this.semanticLabel,
  });

  final IconData icon;
  final int minutes;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Semantics(
      label: semanticLabel,
      excludeSemantics: true,
      child: SizedBox(
        height: _kLegChipHeight,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: cs.onSurfaceVariant),
            const SizedBox(width: 3),
            Text(
              AppI18n.of(context).minutesTight(minutes),
              style: AppTextStyles.timeValue(
                size: AppTextStyles.bodySmall.fontSize,
                color: cs.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LegPill extends StatelessWidget {
  const _LegPill({
    required this.icon,
    required this.label,
    required this.minutes,
    required this.lineColor,
  });

  final IconData icon;
  final String label;
  final int minutes;
  final Color lineColor;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final surface = cs.surfaceContainerHighest;
    return Container(
      height: _kLegChipHeight,
      padding: const EdgeInsets.fromLTRB(
        AppTheme.space6,
        0,
        AppTheme.space8,
        0,
      ),
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(AppTheme.radiusChip),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: legibleLineColor(lineColor, surface)),
          // Hairline between the glyph and the name: the glyph is data about
          // the mode, the name is data about the line, and at this size they
          // read as one word without it.
          Container(
            width: 1,
            height: 12,
            margin: const EdgeInsets.symmetric(horizontal: AppTheme.space6),
            color: cs.outline,
          ),
          Text(
            label,
            style: AppTextStyles.bodySmall.copyWith(
              color: cs.onSurface,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 5),
          Text(
            AppI18n.of(context).minutesTight(minutes),
            style: AppTextStyles.timeValue(
              size: AppTextStyles.bodySmall.fontSize,
              color: cs.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// One height for every chip in the strip, so a wrapped row still reads as a
/// single band rather than a ragged one.
const double _kLegChipHeight = 22;

/// When the journey happens, as one line. Times are mono so the two clocks
/// line up with every other time in the app; the words between them are not.
class _DepartArriveWindow extends StatelessWidget {
  const _DepartArriveWindow({required this.departure, required this.arrival});

  final String departure;
  final String arrival;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final i18n = AppI18n.of(context);
    if (departure.isEmpty && arrival.isEmpty) return const SizedBox.shrink();
    final clock = AppTextStyles.timeValue(
      size: AppTextStyles.bodySmall.fontSize,
      color: cs.onSurfaceVariant,
    );
    // An arrow rather than the words 出發 / 抵達. It is four characters
    // shorter, which is the difference between fitting and ellipsising on a
    // 320pt screen, and the direction is not something a rider has to read.
    if (departure.isEmpty || arrival.isEmpty) {
      return Text(
        departure.isEmpty ? arrival : departure,
        style: clock,
        semanticsLabel: departure.isEmpty
            ? '${i18n.goArriveLabel}$arrival'
            : '$departure${i18n.goDepartSuffix}',
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(departure, style: clock),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 5),
          child: Icon(
            Icons.arrow_right_alt_rounded,
            size: 14,
            color: cs.outline,
          ),
        ),
        Text(arrival, style: clock),
      ],
    );
  }
}

class _Fare extends StatelessWidget {
  const _Fare({required this.amount});

  final int amount;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(
          r'NT$',
          style: AppTextStyles.bodySmall.copyWith(color: cs.onSurfaceVariant),
        ),
        const SizedBox(width: 3),
        Text(
          '$amount',
          style: AppTextStyles.timeValue(
            size: AppTextStyles.bodyRegular.fontSize,
            weight: FontWeight.w600,
            color: cs.onSurface,
          ),
        ),
      ],
    );
  }
}
