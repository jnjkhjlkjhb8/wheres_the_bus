part of 'rail_train_screen.dart';

class _TimetableTab extends StatefulWidget {
  const _TimetableTab({
    required this.stops,
    required this.serviceDate,
    required this.delayMinutes,
    required this.delayUpdatedAt,
    required this.alight,
    this.userOrigin,
    this.picking = false,
    this.leadStops = 0,
    this.onPickStop,
  });

  final int leadStops;

  /// Whether the rider is choosing a 下車站 right now. Stops the train has
  /// already called at, and the boarding stop itself, stay untappable.
  final bool picking;

  final ValueChanged<String>? onPickStop;

  final List<RailTrainStop> stops;
  final String serviceDate;

  /// Live 誤點 for this train, when the caller had it. Shifts the position
  /// marker; the printed times stay as printed, because that is what the
  /// station announcements and the ticket say.
  final int delayMinutes;

  /// When [delayMinutes] last landed, or null before the first frame (and
  /// always for THSR). The stop times are landed timetable; only the delay
  /// laid over them ages, so only it is dated.
  final DateTime? delayUpdatedAt;

  /// The station the rider boards at — their searched origin, or the train's
  /// own first stop.
  final String? userOrigin;

  final String? alight;

  @override
  State<_TimetableTab> createState() => _TimetableTabState();
}

class _TimetableTabState extends State<_TimetableTab> {
  /// Stops the train has already called at stay collapsed behind one line: a
  /// 區間車 runs ~30 stations, and opening the list on the part that has
  /// already happened costs the rider the scroll every time.
  bool _showPast = false;

  int _indexOf(String? name, int fallback) {
    if (name == null) return fallback;
    for (var i = 0; i < widget.stops.length; i++) {
      if (sameStation(widget.stops[i].name, name)) return i;
    }
    return fallback;
  }

  @override
  Widget build(BuildContext context) {
    final stops = widget.stops;
    final last = stops.length - 1;
    final boardIndex = _indexOf(widget.userOrigin, 0);
    final alightIndex = widget.alight == null
        ? null
        : _indexOf(widget.alight, last);
    final position = railPositionIndex(
      stops,
      widget.serviceDate,
      widget.delayMinutes,
      DateTime.now(),
    );

    // Only worth a collapse when it actually hides something: at one passed
    // stop the summary line costs as much room as the row it replaces.
    final collapseUntil = (position != null && position >= 2 && !_showPast)
        ? position - 1
        : -1;

    final children = <Widget>[];
    if (collapseUntil >= 0) {
      children.add(
        _PassedStopsSummary(
          count: collapseUntil + 1,
          names: stops.take(collapseUntil + 1).map((s) => s.name).toList(),
          onExpand: () => setState(() => _showPast = true),
        ),
      );
    }

    // The 提前提醒站, derived rather than picked. Clamped away when the lead
    // would land at or above the boarding stop: a warning for a stop the rider
    // boards at or has already passed is not a warning.
    final leadCandidate = (alightIndex != null && widget.leadStops > 0)
        ? alightIndex - widget.leadStops
        : null;
    final leadIndex = (leadCandidate != null && leadCandidate > boardIndex)
        ? leadCandidate
        : null;

    // One decision for the whole list, not one per row: a column that appears
    // on some rows and not others is a column whose x moves.
    final showElapsed = boardIndex < last;

    for (var i = collapseUntil + 1; i < stops.length; i++) {
      final stop = stops[i];
      final travelled = position != null && i <= position;
      final pickable = widget.picking && i > boardIndex;
      children.add(
        _StopRow(
          stop: stop,
          onPick: pickable && widget.onPickStop != null
              ? () => widget.onPickStop!(stop.name)
              : null,
          isFirst: i == 0,
          isLast: i == last,
          elapsed: i > boardIndex
              ? elapsedMinutes(widget.serviceDate, stops[boardIndex], stop)
              : null,
          // The spine's covered track ends at the train, so the segment above
          // the marker row is solid and everything past it is not.
          travelledAbove: travelled,
          travelledBelow: position != null && i < position,
          isBoard: widget.userOrigin != null && i == boardIndex,
          isAlight: alightIndex != null && i == alightIndex,
          isLeadStop: leadIndex != null && i == leadIndex,
          showElapsed: showElapsed,
        ),
      );
    }

    if (widget.delayUpdatedAt != null) {
      children.add(
        Padding(
          padding: const EdgeInsets.all(AppTheme.space16),
          child: Center(child: FreshnessStamp(at: widget.delayUpdatedAt)),
        ),
      );
    }

    return Column(
      children: [
        _TimetableColumnHeader(showElapsed: showElapsed),
        Expanded(
          child: ListView(padding: EdgeInsets.zero, children: children),
        ),
      ],
    );
  }
}

class _TimetableColumnHeader extends StatelessWidget {
  const _TimetableColumnHeader({required this.showElapsed});

  /// The 歷時 column is only meaningful when there is a downstream segment to
  /// measure; a rider boarding at the terminus has nothing to accumulate.
  final bool showElapsed;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final style = AppTextStyles.bodyVerySmall.copyWith(
      color: cs.onSurfaceVariant,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.4,
    );

    return Container(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: cs.outlineVariant, width: 0.5),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(
        kTimelineGutter,
        AppTheme.space8,
        AppTheme.space16,
        AppTheme.space6,
      ),
      child: Row(
        children: [
          Text(AppI18n.of(context).railColStation, style: style),
          const Spacer(),
          // Same fixed widths as the rows below, so each heading sits over its
          // own column rather than over wherever that row's content ended.
          SizedBox(
            width: scaledWidth(context, _StopRow.timeWidth),
            child: Text(
              AppI18n.of(context).railColTime,
              textAlign: TextAlign.right,
              style: style,
            ),
          ),
          if (showElapsed) ...[
            const SizedBox(width: AppTheme.space12),
            SizedBox(
              width: scaledWidth(context, _StopRow.elapsedWidth),
              child: Text(
                AppI18n.of(context).railColElapsed,
                textAlign: TextAlign.right,
                style: style,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _PassedStopsSummary extends StatelessWidget {
  const _PassedStopsSummary({
    required this.count,
    required this.names,
    required this.onExpand,
  });

  final int count;
  final List<String> names;
  final VoidCallback onExpand;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // Name the first few so the collapse is verifiable at a glance rather than
    // asking the rider to expand just to confirm which stops it swallowed.
    final preview = names.take(3).join('、');
    final suffix = names.length > 3 ? '⋯' : '';

    return Pressable(
      onTap: onExpand,
      semanticLabel: AppI18n.of(context).railStopsPassed(count),
      child: Container(
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(color: cs.outlineVariant, width: 0.5),
          ),
        ),
        padding: const EdgeInsets.fromLTRB(0, 9, AppTheme.space16, 9),
        child: Row(
          children: [
            SizedBox(
              width: kTimelineGutter,
              child: Center(
                child: Container(
                  width: 2,
                  height: 22,
                  decoration: BoxDecoration(
                    color: cs.outline,
                    borderRadius: BorderRadius.circular(1),
                  ),
                ),
              ),
            ),
            Expanded(
              child: Text(
                AppI18n.of(
                  context,
                ).railStopsPassedPreview(count, '$preview$suffix'),
                style: AppTextStyles.bodySmall.copyWith(
                  color: cs.onSurfaceVariant,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: AppTheme.space6),
            Icon(
              Icons.keyboard_arrow_down_rounded,
              size: 18,
              color: cs.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}

class _StopRow extends StatelessWidget {
  const _StopRow({
    required this.stop,
    required this.isFirst,
    required this.isLast,
    required this.elapsed,
    required this.travelledAbove,
    required this.travelledBelow,
    required this.isBoard,
    required this.isAlight,
    required this.showElapsed,
    this.isLeadStop = false,
    this.onPick,
  });

  /// The 提前提醒站. A bare bell, no fill and no row highlight: the app derived
  /// this row from 提前站數, where 下車站 is the one the rider chose.
  final bool isLeadStop;

  /// Set only while the rider is choosing a 下車站 and this row is a candidate.
  /// Rows without it stay plain text, which is what makes the pickable ones
  /// read as the choice on offer.
  final VoidCallback? onPick;

  final RailTrainStop stop;

  /// Origin stop of the train's run: an arrival time here is meaningless.
  final bool isFirst;

  /// Terminus stop of the train's run: a departure time here is meaningless.
  final bool isLast;

  /// Minutes from the boarding stop, or null upstream of it.
  final int? elapsed;

  final bool travelledAbove;
  final bool travelledBelow;
  final bool isBoard;
  final bool isAlight;

  /// Whether the 歷時 column exists on this list at all. Uniform across every
  /// row so the column keeps one x; a per-row decision is what let the times
  /// wander in the first place.
  final bool showElapsed;

  static const double timeWidth = 58;
  static const double elapsedWidth = 46;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final marked = isBoard || isAlight;
    final primaryTime = isFirst
        ? stop.depart
        : (stop.arrive.isNotEmpty ? stop.arrive : stop.depart);
    // TRA prints a one-minute dwell at nearly every station: the default, not
    // information. Only a wait worth noticing is called out.
    final dwell = isLast ? 0 : dwellMinutes(stop);

    final row = Container(
      constraints: const BoxConstraints(minHeight: 48),
      // The static, non-pulsing highlight the design system reserves for
      // "find this row" cases — fill and weight only, no new colour.
      color: isAlight ? cs.surfaceContainerHighest : null,
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TimelineSpine(
              kind: marked
                  ? TimelineNodeKind.emphasis
                  : (isFirst || isLast
                        ? TimelineNodeKind.terminus
                        : TimelineNodeKind.intermediate),
              lineAbove: !isFirst,
              lineBelow: !isLast,
              travelledAbove: travelledAbove,
              travelledBelow: travelledBelow,
            ),
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(color: cs.outlineVariant, width: 0.5),
                  ),
                ),
                padding: const EdgeInsets.fromLTRB(0, 11, AppTheme.space16, 11),
                child: Row(
                  children: [
                    Expanded(
                      child: Row(
                        children: [
                          Flexible(
                            child: Text(
                              stop.name,
                              style: AppTextStyles.bodyRegular.copyWith(
                                height: 1.3,
                                fontWeight: marked ? FontWeight.w700 : null,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (isBoard) ...[
                            const SizedBox(width: AppTheme.space6),
                            TimelineStopTag(
                              AppI18n.of(context).railBoard,
                              solid: false,
                            ),
                          ],
                          if (isAlight) ...[
                            const SizedBox(width: AppTheme.space6),
                            TimelineStopTag(AppI18n.of(context).railAlight),
                          ],
                          if (isLeadStop) ...[
                            const SizedBox(width: AppTheme.space6),
                            Icon(
                              Icons.notifications_rounded,
                              size: 16,
                              color: cs.onSurfaceVariant,
                            ),
                          ],
                          // The dwell note rides in the flexible area rather
                          // than in the time slot: a variable-width note inside
                          // a fixed column either clips or drags it off its x.
                          if (dwell >= 2) ...[
                            const SizedBox(width: AppTheme.space8),
                            Text(
                              AppI18n.of(context).railDwellMinutes(dwell),
                              style: AppTextStyles.bodySmall.copyWith(
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    SizedBox(
                      width: scaledWidth(context, timeWidth),
                      child: Text(
                        primaryTime.isEmpty ? '' : hhmm(primaryTime),
                        textAlign: TextAlign.right,
                        style: AppTextStyles.timeValue(
                          size: 15,
                          weight: FontWeight.w600,
                          color: cs.onSurface,
                        ),
                      ),
                    ),
                    // Reserved even when this row has no figure, so the column
                    // holds its x down the whole list instead of every
                    // upstream row shunting the times right by its width.
                    if (showElapsed) ...[
                      const SizedBox(width: AppTheme.space12),
                      SizedBox(
                        width: scaledWidth(context, elapsedWidth),
                        child: Text(
                          elapsed == null
                              ? ''
                              : AppI18n.of(context).railElapsedPlus(elapsed!),
                          textAlign: TextAlign.right,
                          style: AppTextStyles.timeValue(
                            size: 12,
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );

    if (onPick == null) return row;
    return Pressable(
      onTap: onPick,
      semanticLabel: AppI18n.of(context).alightPickStopSemantics(stop.name),
      child: row,
    );
  }
}
