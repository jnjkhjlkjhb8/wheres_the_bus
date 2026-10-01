part of '../view/go_screen.dart';

/// Plan-preview sheet: the single selected route shown as a full itinerary on
/// the same map-and-sheet screen. Swaps in for the results list when a route is
/// selected; navigation can only be started from here.
class _PreviewSheet extends StatelessWidget {
  const _PreviewSheet({
    required this.controller,
    required this.initialOffset,
    required this.route,
    required this.isFastest,
    required this.isSaved,
    required this.origin,
    required this.dest,
    required this.onBack,
    required this.onStartNavigation,
    required this.onToggleSave,
    super.key,
  });

  final SheetController controller;
  final SheetOffset initialOffset;
  final PlanRoute route;

  /// Whether this route is the fastest of a multi-route result (drives 最快).
  final bool isFastest;
  final bool isSaved;
  final String? origin;
  final String? dest;
  final VoidCallback onBack;
  final VoidCallback onStartNavigation;
  final VoidCallback onToggleSave;

  @override
  Widget build(BuildContext context) {
    final sections = route.sections;
    final firstDeparture = sections.isEmpty
        ? ''
        : sections.first.departure.name;
    final originName = _firstNonEmpty([
      origin,
      firstDeparture,
      AppI18n.of(context).goOriginFallback,
    ]);
    // _lastNamedArrival always resolves (falls back to 目的地).
    final destName = _firstNonEmpty([
      dest,
      _lastNamedArrival(AppI18n.of(context), sections),
    ]);
    return AppSheet(
      controller: controller,
      initialOffset: initialOffset,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SheetDragHandle(),
          _PreviewSummaryHeader(
            route: route,
            originName: originName,
            destName: destName,
            isFastest: isFastest,
            isSaved: isSaved,
            onBack: onBack,
            onToggleSave: onToggleSave,
          ),
          const DividerLine(),
          Expanded(
            child: _PreviewItinerary(route: route, destName: destName),
          ),
          _PreviewFooter(onStartNavigation: onStartNavigation),
        ],
      ),
    );
  }
}

String _firstNonEmpty(List<String?> candidates) {
  for (final c in candidates) {
    if (c != null && c.isNotEmpty) return c;
  }
  return '';
}

/// Header: back chevron + origin→destination summary, then the big mono minutes
/// with the 最快 badge and metadata (出發 above 抵達, fare, walk time).
class _PreviewSummaryHeader extends StatelessWidget {
  const _PreviewSummaryHeader({
    required this.route,
    required this.originName,
    required this.destName,
    required this.isFastest,
    required this.isSaved,
    required this.onBack,
    required this.onToggleSave,
  });

  final PlanRoute route;
  final String originName;
  final String destName;
  final bool isFastest;
  final bool isSaved;
  final VoidCallback onBack;
  final VoidCallback onToggleSave;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final minutes = routeMinutes(route);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppTheme.space12,
        0,
        AppTheme.space16,
        AppTheme.space12,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Pressable(
                onTap: onBack,
                semanticLabel: AppI18n.of(context).goBackToRouteList,
                child: SizedBox(
                  width: 40,
                  height: 40,
                  child: Icon(
                    Icons.chevron_left_rounded,
                    size: 26,
                    color: cs.onSurface,
                  ),
                ),
              ),
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        originName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTextStyles.bodySmall.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppTheme.space6,
                      ),
                      child: Icon(
                        Icons.arrow_forward_rounded,
                        size: 13,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                    Flexible(
                      child: Text(
                        destName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTextStyles.bodySmall.copyWith(
                          color: cs.onSurface,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              _PreviewSaveButton(saved: isSaved, onTap: onToggleSave),
            ],
          ),
          const SizedBox(height: AppTheme.space8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppTheme.space4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
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
                          const SizedBox(width: AppTheme.space2),
                          Padding(
                            padding: const EdgeInsets.only(
                              bottom: AppTheme.space2,
                            ),
                            child: Text(
                              AppI18n.of(context).goMinutesUnit,
                              style: AppTextStyles.bodySmall.copyWith(
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                          ),
                          if (isFastest) ...[
                            const SizedBox(width: AppTheme.space8),
                            _PreviewBadge(
                              label: AppI18n.of(context).goBadgeFastest,
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: AppTheme.space6),
                      _PreviewMeta(route: route),
                    ],
                  ),
                ),
                const SizedBox(width: AppTheme.space12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    _PreviewClock(
                      label: AppI18n.of(context).busDepart,
                      value: formatClock(route.startTime),
                    ),
                    const SizedBox(height: AppTheme.space4),
                    _PreviewClock(
                      label: AppI18n.of(context).railColArrive,
                      value: formatClock(route.endTime),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Walk time and fare line under the minutes. Fare is omitted when unresolved.
class _PreviewMeta extends StatelessWidget {
  const _PreviewMeta({required this.route});

  final PlanRoute route;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        Icon(
          Icons.directions_walk_rounded,
          size: 14,
          color: cs.onSurfaceVariant,
        ),
        const SizedBox(width: AppTheme.space4),
        Text(
          AppI18n.of(context).walkMinutes(walkMinutes(route)),
          style: AppTextStyles.bodySmall.copyWith(color: cs.onSurfaceVariant),
        ),
        if (route.totalFare > 0) ...[
          const SizedBox(width: AppTheme.space12),
          Text(
            r'NT$ ',
            style: AppTextStyles.bodySmall.copyWith(color: cs.onSurfaceVariant),
          ),
          Text(
            '${route.totalFare}',
            style: AppTextStyles.timeValue(
              size: AppTextStyles.bodySmall.fontSize,
              color: cs.onSurface,
            ),
          ),
        ],
      ],
    );
  }
}

/// A stacked label + mono time value (出發 / 抵達).
class _PreviewClock extends StatelessWidget {
  const _PreviewClock({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (value.isEmpty) return const SizedBox.shrink();
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(
          label,
          style: AppTextStyles.bodySmall.copyWith(color: cs.onSurfaceVariant),
        ),
        const SizedBox(width: AppTheme.space6),
        Text(
          value,
          style: AppTextStyles.timeValue(
            size: 15,
            weight: FontWeight.w600,
            color: cs.onSurface,
          ),
        ),
      ],
    );
  }
}

/// Solid Ink pill badge (最快). Mirrors the results card badge vocabulary.
class _PreviewBadge extends StatelessWidget {
  const _PreviewBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTheme.space6,
        vertical: AppTheme.space2,
      ),
      decoration: BoxDecoration(
        color: cs.onSurface,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: AppTextStyles.bodyVerySmall.copyWith(
          color: cs.surface,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

class _PreviewSaveButton extends StatelessWidget {
  const _PreviewSaveButton({required this.saved, required this.onTap});

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
      child: SizedBox(
        width: 40,
        height: 40,
        child: AnimatedSwitcher(
          duration: AppMotion.short,
          child: Icon(
            saved ? Icons.bookmark_rounded : Icons.bookmark_border_rounded,
            key: ValueKey(saved),
            size: 20,
            color: saved ? cs.onSurface : cs.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

class _PreviewItinerary extends StatelessWidget {
  const _PreviewItinerary({required this.route, required this.destName});

  final PlanRoute route;
  final String destName;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final sections = route.sections;
    final rows = <Widget>[];
    for (final (i, s) in sections.indexed) {
      final walk = isWalk(s);
      rows.add(
        _PreviewRow(
          nodeRing: _nodeRing(i, sections, cs),
          nodeFilled: false,
          connectorColor: walk
              ? cs.outlineVariant
              : transitColor(s.transport, cs),
          dashed: walk,
          showConnector: true,
          minutes: sectionMinutes(s),
          content: walk
              ? _walkContent(context, i, s)
              : _transitContent(context, i, s),
        ),
      );
    }
    rows.add(
      _PreviewRow(
        nodeRing: cs.onSurface,
        nodeFilled: true,
        connectorColor: cs.outlineVariant,
        dashed: false,
        showConnector: false,
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              destName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTextStyles.bodyLarge.copyWith(
                fontWeight: FontWeight.w700,
                color: cs.onSurface,
              ),
            ),
            if (formatClock(route.endTime).isNotEmpty) ...[
              const SizedBox(height: AppTheme.space2),
              Text(
                AppI18n.of(context).arriveAtTime(formatClock(route.endTime)),
                style: AppTextStyles.bodySmall.copyWith(
                  color: cs.onSurfaceVariant,
                  fontFeatures: AppTextStyles.tabularFigures,
                ),
              ),
            ],
          ],
        ),
      ),
    );
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppTheme.space20,
        AppTheme.space14,
        AppTheme.space20,
        AppTheme.space12,
      ),
      children: rows,
    );
  }

  // Ring color for section i's departure node: origin is Ink, a boarding node
  // takes its own leg color, an alighting-into-walk node takes the previous
  // leg's color, else Ink.
  Color _nodeRing(int i, List<PlanSection> sections, ColorScheme cs) {
    if (i == 0) return cs.onSurface;
    final s = sections[i];
    if (!isWalk(s)) return transitColor(s.transport, cs);
    final prev = sections[i - 1];
    if (!isWalk(prev)) return transitColor(prev.transport, cs);
    return cs.onSurface;
  }

  Widget _walkContent(BuildContext context, int i, PlanSection s) {
    final cs = Theme.of(context).colorScheme;
    final sections = route.sections;
    final nextBoard = i + 1 < sections.length
        ? sections[i + 1].departure.name
        : '';
    final target = _firstNonEmpty([s.arrival.name, nextBoard, destName]);
    return Text(
      AppI18n.of(context).walkTo(target),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: AppTextStyles.bodyRegular.copyWith(
        fontWeight: FontWeight.w600,
        color: cs.onSurface,
      ),
    );
  }

  Widget _transitContent(BuildContext context, int i, PlanSection s) {
    final cs = Theme.of(context).colorScheme;
    final color = transitColor(s.transport, cs);
    final rideStops = s.intermediateStops.length + 1;
    final headsign = s.transport.headsign;
    final legLine = headsign.isNotEmpty
        ? AppI18n.of(context).rideStopsTowards(rideStops, headsign)
        : AppI18n.of(context).rideStops(rideStops);
    // The wait belongs to the place the rider stands in, so it sits above the
    // line badge — chronologically the wait comes before boarding, and the
    // row's minutes column stays the ride itself.
    final wait = waitMinutesBefore(route.sections, i);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (wait > 0) ...[
          _WaitLine(minutes: wait),
          const SizedBox(height: AppTheme.space6),
        ],
        AppBadge(label: sectionLabel(AppI18n.of(context), s), color: color),
        const SizedBox(height: AppTheme.space6),
        Text(
          '${s.departure.name} → ${s.arrival.name}',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: AppTextStyles.bodyRegular.copyWith(
            fontWeight: FontWeight.w600,
            color: cs.onSurface,
          ),
        ),
        const SizedBox(height: AppTheme.space2),
        Text(
          legLine,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppTextStyles.bodySmall.copyWith(color: cs.onSurfaceVariant),
        ),
      ],
    );
  }
}

/// Scheduled waiting at a boarding place, stated on the leg that departs from
/// it.
class _WaitLine extends StatelessWidget {
  const _WaitLine({required this.minutes});

  final int minutes;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tone = cs.onSurfaceVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.hourglass_empty_rounded, size: 14, color: tone),
        const SizedBox(width: AppTheme.space4),
        Text(
          AppI18n.of(context).transferWaitMinutes(minutes),
          style: AppTextStyles.bodySmall.copyWith(color: tone),
        ),
      ],
    );
  }
}

/// One timeline row: the left rail (node + connector) beside the section
/// content, with right-aligned mono minutes.
class _PreviewRow extends StatelessWidget {
  const _PreviewRow({
    required this.nodeRing,
    required this.nodeFilled,
    required this.connectorColor,
    required this.dashed,
    required this.showConnector,
    required this.content,
    this.minutes,
  });

  final Color nodeRing;
  final bool nodeFilled;
  final Color connectorColor;
  final bool dashed;
  final bool showConnector;
  final Widget content;
  final int? minutes;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 24,
            child: Column(
              children: [
                _node(cs),
                if (showConnector)
                  Expanded(
                    child: CustomPaint(
                      size: const Size(24, double.infinity),
                      painter: _ConnectorPainter(
                        color: connectorColor,
                        dashed: dashed,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: AppTheme.space14),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(
                bottom: showConnector ? AppTheme.space20 : 0,
              ),
              child: content,
            ),
          ),
          if (minutes != null) ...[
            const SizedBox(width: AppTheme.space12),
            Text(
              AppI18n.of(context).minutesValue(minutes!),
              style: AppTextStyles.timeValue(
                size: AppTextStyles.bodyRegular.fontSize,
                weight: FontWeight.w700,
                color: cs.onSurface,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _node(ColorScheme cs) {
    if (nodeFilled) {
      // Destination: Ink-filled disc with a small white inner dot — the
      // heaviest node, mirroring the map's destination marker.
      return Container(
        width: 20,
        height: 20,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: nodeRing, shape: BoxShape.circle),
        child: Container(
          width: 7,
          height: 7,
          decoration: const BoxDecoration(
            color: Colors.white,
            shape: BoxShape.circle,
          ),
        ),
      );
    }
    return Container(
      width: 18,
      height: 18,
      decoration: BoxDecoration(
        color: cs.surface,
        shape: BoxShape.circle,
        border: Border.all(color: nodeRing, width: 2.5),
      ),
    );
  }
}

/// Pinned primary CTA that commits the previewed route to navigation.
class _PreviewFooter extends StatelessWidget {
  const _PreviewFooter({required this.onStartNavigation});

  final VoidCallback onStartNavigation;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;
    return Container(
      decoration: BoxDecoration(
        color: cs.surface,
        border: Border(top: BorderSide(color: cs.outlineVariant)),
      ),
      padding: EdgeInsets.fromLTRB(
        AppTheme.space20,
        AppTheme.space12,
        AppTheme.space20,
        AppTheme.space12 + bottomInset,
      ),
      child: SizedBox(
        width: double.infinity,
        child: AppButton(
          label: AppI18n.of(context).goStartNavigation,
          onPressed: onStartNavigation,
        ),
      ),
    );
  }
}

/// Vertical spine line, centered in its box. Dashed for walk segments to match
/// the map's dotted-walk polylines.
class _ConnectorPainter extends CustomPainter {
  const _ConnectorPainter({required this.color, required this.dashed});

  final Color color;
  final bool dashed;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    final x = size.width / 2;
    if (!dashed) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
      return;
    }
    const dash = 3.0;
    const gap = 5.0;
    for (var y = 0.0; y < size.height; y += dash + gap) {
      final end = (y + dash).clamp(0.0, size.height);
      canvas.drawLine(Offset(x, y), Offset(x, end), paint);
    }
  }

  @override
  bool shouldRepaint(_ConnectorPainter old) =>
      old.color != color || old.dashed != dashed;
}
