part of '../view/bus_route_screen.dart';

class _Fares extends StatelessWidget {
  const _Fares({required this.cs, required this.fare});
  final ColorScheme cs;
  final BusFareInfo? fare;

  @override
  Widget build(BuildContext context) {
    final fare = this.fare;
    final od = decodeOdFares(AppI18n.of(context), fare);
    // City buses have no origin→destination table; their class rows are short
    // enough to sit inline. Only 公路客運 with an OD table gets the accordion.
    final flatGroups = od.isEmpty
        ? decodeFareTable(AppI18n.of(context), fare)
        : const <FareGroup>[];
    final odCount = od.fold<int>(0, (n, o) => n + o.destinations.length);

    return FarePreferenceBuilder(
      builder: (context, fareType) {
        final range = odFareRange(od, fareType);
        // A genuine range (min != max) means the OD table really does carry
        // per-stop variation, which contradicts TDX's own 一段票 (flat-fare)
        // label for some routes — reconcile them instead of showing both.
        final hasFareRange =
            od.isNotEmpty && range != null && range.min != range.max;
        // Every class the route prices, for the 全部票種 disclosure. A route
        // that only ever publishes 全票 gets no disclosure rather than one
        // that opens onto a single row the rider is already looking at.
        final allClasses = _fareClassCount(flatGroups, od);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: AppTheme.space12,
          children: [
            _SectionLabel(AppI18n.of(context).busFareInfo, cs: cs),
            if (fare == null)
              _EmptyDetailText(AppI18n.of(context).busNoFare, cs: cs)
            else ...[
              AppCard.outlined(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: _FareFact(
                            label: AppI18n.of(context).busFarePricingType,
                            value: _farePricingTypeLabel(
                              AppI18n.of(context),
                              fare.pricingType,
                              hasFareRange: hasFareRange,
                            ),
                            cs: cs,
                          ),
                        ),
                        // "需付費" told the rider nothing they didn't already
                        // know; 免費 is the only value of this fact worth a
                        // slot.
                        if (fare.isFreeBus)
                          _FareFact(
                            label: AppI18n.of(context).busFareChargingMethod,
                            value: AppI18n.of(context).busFareFree,
                            alignEnd: true,
                            cs: cs,
                          ),
                      ],
                    ),
                    if (od.isNotEmpty && range != null)
                      _FareRangeLine(
                        range: range,
                        fareType: fareType,
                        cs: cs,
                      )
                    else
                      for (final (i, group) in flatGroups.indexed)
                        _FareGroupBlock(
                          group: group,
                          fareType: fareType,
                          showDivider: i > 0,
                          cs: cs,
                        ),
                  ],
                ),
              ),
              // The rider's own ticket type is the headline above; the rest of
              // the classes stay one tap away rather than stacking six rows
              // per segment on a screen read at a bus stop.
              if (allClasses > 1 && flatGroups.isNotEmpty)
                AppAccordion(
                  title: AppI18n.of(
                    context,
                  ).busAllFareClasses(allClasses),
                  child: _AllFareClasses(groups: flatGroups, cs: cs),
                ),
              if (od.isNotEmpty)
                AppAccordion(
                  title: AppI18n.of(
                    context,
                  ).busAllOdFares(odCount),
                  child: _OdFareTable(
                    origins: od,
                    fareType: fareType,
                    cs: cs,
                  ),
                ),
            ],
          ],
        );
      },
    );
  }
}

/// How many distinct fare classes the route prices anywhere, which decides
/// whether a 全部票種 disclosure has anything to disclose.
int _fareClassCount(List<FareGroup> groups, List<OdOrigin> origins) {
  final classes = <int>{};
  for (final group in groups) {
    for (final row in group.rows) {
      classes.add(row.fareClass);
    }
  }
  for (final origin in origins) {
    for (final dest in origin.destinations) {
      for (final row in dest.rows) {
        classes.add(row.fareClass);
      }
    }
  }
  return classes.length;
}

/// Every fare class the route prices, per segment. The rider's own type is
/// already shown above, so this is reference material: a plain label/price
/// list, no highlighting, no second hierarchy competing with the headline.
class _AllFareClasses extends StatelessWidget {
  const _AllFareClasses({required this.groups, required this.cs});
  final List<FareGroup> groups;
  final ColorScheme cs;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (i, group) in groups.indexed) ...[
          if (i > 0)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: AppTheme.space12),
              child: DividerLine(),
            ),
          if (group.segment case final segment?)
            Padding(
              padding: EdgeInsets.only(
                top: i > 0 ? 0 : AppTheme.space4,
                bottom: AppTheme.space2,
              ),
              child: Text(
                segment,
                style: AppTextStyles.bodySmall.copyWith(
                  fontWeight: FontWeight.w600,
                  color: cs.onSurface,
                ),
              ),
            ),
          for (final row in group.rows)
            Padding(
              padding: const EdgeInsets.only(top: AppTheme.space10),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      row.label,
                      style: AppTextStyles.bodyRegular.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                  Text(
                    row.price,
                    style: AppTextStyles.bodyRegular.copyWith(
                      fontFeatures: _tnum,
                      color: cs.onSurface,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ],
    );
  }
}

class _FareRangeLine extends StatelessWidget {
  const _FareRangeLine({
    required this.range,
    required this.fareType,
    required this.cs,
  });
  final ({int min, int max}) range;

  /// The ticket type [range] was computed for. Named on the row, because a
  /// range with no ticket type beside it reads as the standard fare.
  final FareType fareType;
  final ColorScheme cs;

  @override
  Widget build(BuildContext context) {
    final i18n = AppI18n.of(context);
    final label = range.min == range.max
        ? 'NT\$${range.min}'
        : 'NT\$${range.min} – NT\$${range.max}';
    return Padding(
      padding: const EdgeInsets.only(top: AppTheme.space12),
      child: Row(
        children: [
          Expanded(
            child: Text(
              i18n.busFareRange(fareType.labelOf(i18n)),
              style: AppTextStyles.bodyRegular.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
          ),
          Text(
            label,
            style: AppTextStyles.bodyLarge.copyWith(
              fontFeatures: _tnum,
              fontWeight: FontWeight.w600,
              color: cs.onSurface,
            ),
          ),
        ],
      ),
    );
  }
}

/// Searchable, origin-grouped 起迄 fare table. Rendered inside a collapsed
/// accordion, so it never dominates the detail tab. Rows are capped and the
/// remainder surfaced through search rather than an endless flat list.
class _OdFareTable extends StatefulWidget {
  const _OdFareTable({
    required this.origins,
    required this.fareType,
    required this.cs,
  });
  final List<OdOrigin> origins;

  /// The rider's ticket type. Each destination shows the one price they pay;
  /// listing every class per destination turned an 80-row table into a 300-row
  /// one nobody scrolled to the bottom of.
  final FareType fareType;
  final ColorScheme cs;

  @override
  State<_OdFareTable> createState() => _OdFareTableState();
}

class _OdFareTableState extends State<_OdFareTable> {
  static const int _maxRows = 80;
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final cs = widget.cs;
    final q = _query.trim();
    // An origin match shows all its destinations; otherwise only the
    // destinations whose name matches, dropping origins with no hit.
    final matches = <OdOrigin>[];
    for (final origin in widget.origins) {
      if (q.isEmpty || origin.origin.contains(q)) {
        matches.add(origin);
        continue;
      }
      final dests = [
        for (final d in origin.destinations)
          if (d.destination.contains(q)) d,
      ];
      if (dests.isNotEmpty) {
        matches.add((origin: origin.origin, destinations: dests));
      }
    }

    final blocks = <Widget>[];
    var shown = 0;
    var truncated = false;
    for (final origin in matches) {
      if (shown >= _maxRows) {
        truncated = true;
        break;
      }
      final dests = origin.destinations.length + shown > _maxRows
          ? origin.destinations.sublist(0, _maxRows - shown)
          : origin.destinations;
      if (dests.length < origin.destinations.length) truncated = true;
      blocks.add(_originBlock(origin.origin, dests, cs));
      shown += dests.length;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppInput(
          label: AppI18n.of(context).busSearchStops,
          hint: AppI18n.of(context).busSearchStopsHint,
          prefixIcon: Icon(
            Icons.search,
            size: 20,
            color: cs.onSurfaceVariant,
          ),
          onChanged: (v) => setState(() => _query = v),
        ),
        const SizedBox(height: AppTheme.space8),
        if (matches.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: AppTheme.space16),
            child: Text(
              AppI18n.of(context).busNoStopMatch(q),
              style: AppTextStyles.bodyRegular.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
          )
        else ...[
          ...blocks,
          if (truncated)
            Padding(
              padding: const EdgeInsets.only(top: AppTheme.space12),
              child: Text(
                AppI18n.of(context).busFareTruncated(_maxRows),
                style: AppTextStyles.bodySmall.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ],
    );
  }

  Widget _originBlock(
    String origin,
    List<OdDestination> dests,
    ColorScheme cs,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(
            top: AppTheme.space12,
            bottom: AppTheme.space2,
          ),
          child: Row(
            children: [
              Text(
                origin,
                style: AppTextStyles.bodySmall.copyWith(
                  fontWeight: FontWeight.w600,
                  color: cs.onSurface,
                ),
              ),
              const SizedBox(width: AppTheme.space4),
              Text(
                AppI18n.of(context).busDepart,
                style: AppTextStyles.bodySmall.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        for (final dest in dests) _destRow(dest, cs),
      ],
    );
  }

  Widget _destRow(OdDestination dest, ColorScheme cs) {
    final picked = pickFareRow(dest.rows, widget.fareType);
    if (picked == null) return const SizedBox.shrink();
    // The class label rides along only when it is not what the rider asked
    // for — otherwise the whole column repeats their own ticket type on every
    // row, which the section heading already states once.
    final needsLabel = picked.matched != widget.fareType;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              dest.destination,
              style: AppTextStyles.bodyRegular.copyWith(color: cs.onSurface),
            ),
          ),
          Text(
            needsLabel
                ? '${picked.row.label} ${picked.row.price}'
                : picked.row.price,
            style: AppTextStyles.bodyRegular.copyWith(
              fontFeatures: _tnum,
              fontWeight: FontWeight.w600,
              color: cs.onSurface,
            ),
          ),
        ],
      ),
    );
  }
}

/// One segment's headline price: the single row the rider actually pays. Every
/// other class for the segment lives in the 全部票種 disclosure — stacking all
/// six here is what made this block unreadable at a stop.
class _FareGroupBlock extends StatelessWidget {
  const _FareGroupBlock({
    required this.group,
    required this.fareType,
    required this.showDivider,
    required this.cs,
  });
  final FareGroup group;
  final FareType fareType;
  final bool showDivider;
  final ColorScheme cs;

  @override
  Widget build(BuildContext context) {
    final i18n = AppI18n.of(context);
    final picked = pickFareRow(group.rows, fareType);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Separate consecutive segments (公路客運 起迄 / 分段) with a hairline so
        // each origin→destination block reads as its own fare panel.
        if (showDivider)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: AppTheme.space12),
            child: DividerLine(),
          ),
        if (group.segment case final segment?)
          Padding(
            padding: EdgeInsets.only(
              top: showDivider ? 0 : AppTheme.space12,
              bottom: AppTheme.space4,
            ),
            child: Text(
              segment,
              style: AppTextStyles.bodySmall.copyWith(
                fontWeight: FontWeight.w600,
                color: cs.onSurface,
              ),
            ),
          ),
        if (picked != null)
          Padding(
            padding: const EdgeInsets.only(top: AppTheme.space12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    // The matched label, not the requested one: a segment that
                    // prices no 敬老票 says 全票 here rather than mislabelling
                    // the standard fare as a concession.
                    picked.matched == fareType
                        ? picked.row.label
                        : i18n.busFareMissing(
                            picked.row.label,
                            fareType.labelOf(i18n),
                          ),
                    style: AppTextStyles.bodyRegular.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ),
                Text(
                  picked.row.price,
                  style: AppTextStyles.bodyLarge.copyWith(
                    fontFeatures: _tnum,
                    fontWeight: FontWeight.w600,
                    color: cs.onSurface,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _FareFact extends StatelessWidget {
  const _FareFact({
    required this.label,
    required this.value,
    required this.cs,
    this.alignEnd = false,
  });
  final String label;
  final String value;
  final ColorScheme cs;
  final bool alignEnd;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: alignEnd
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      spacing: 3,
      children: [
        Text(
          label,
          style: AppTextStyles.bodySmall.copyWith(color: cs.onSurfaceVariant),
        ),
        Text(
          value,
          style: AppTextStyles.bodyLarge.copyWith(
            fontWeight: FontWeight.w600,
            color: cs.onSurface,
          ),
        ),
      ],
    );
  }
}
