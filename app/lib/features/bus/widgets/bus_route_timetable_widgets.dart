part of '../view/bus_route_screen.dart';

class _Timetable extends StatefulWidget {
  const _Timetable({
    required this.cs,
    required this.headsign,
    required this.state,
  });
  final ColorScheme cs;
  final String headsign;
  final BusRouteState state;

  static const int _columns = 4;

  @override
  State<_Timetable> createState() => _TimetableState();
}

class _TimetableState extends State<_Timetable> {
  late int _day = busWeekdayIndex(DateTime.now());

  ColorScheme get cs => widget.cs;

  @override
  Widget build(BuildContext context) {
    final schedules = _schedulesFor(widget.state);
    final serviceDays = busServiceDays(schedules);
    final timetable = _timetableFor(widget.state, _day);
    final today = busWeekdayIndex(DateTime.now());
    // Without a weekly pattern only today is knowable: showing a day picker
    // would offer six answers the data cannot give.
    final weekly = serviceDays.isNotEmpty;
    final reduceMotion = AppMotion.reduced(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: AppTheme.space12,
      children: [
        _SectionLabel(AppI18n.of(context).busTimetable, cs: cs),
        if (!weekly && timetable.departures.isEmpty)
          _EmptyDetailText(AppI18n.of(context).busNoTimetable, cs: cs)
        else ...[
          if (weekly)
            AppSlidingSegment<int>(
              options: {
                for (final (i, label) in _dtWeekdayLabels(
                  AppI18n.of(context),
                ).indexed)
                  i: label,
              },
              value: _day,
              // A day the route does not run reads as an answer before the tap
              // — the muted label is the "沒有班" the picker exists to give.
              muted: {
                for (var d = 0; d < 7; d++)
                  if (!serviceDays.contains(d) &&
                      !(d == today && timetable.departures.isNotEmpty))
                    d,
              },
              onChanged: (day) => setState(() => _day = day),
            ),
          AnimatedSize(
            duration: reduceMotion ? AppMotion.instant : AppMotion.micro,
            curve: AppMotion.easeOut,
            alignment: Alignment.topCenter,
            child: AnimatedSwitcher(
              // The board is data, so days cross-fade in place rather than
              // sliding: nothing travels, the numbers just change.
              duration: reduceMotion ? AppMotion.instant : AppMotion.micro,
              switchInCurve: AppMotion.easeOut,
              switchOutCurve: AppMotion.easeOut,
              child: KeyedSubtree(
                key: ValueKey((_day, widget.state.direction)),
                child: AppCard.outlined(
                  padding: EdgeInsets.zero,
                  child: _board(timetable),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  String _dayLabel(AppI18n i18n) =>
      i18n.busWeekday(_dtWeekdayLabels(i18n)[_day]);

  Widget _board(BusDayTimetable timetable) {
    final rows = timetable.departures;
    // Chunk the day's departures into fixed-width columns so the board reads as
    // a scannable timetable rather than a list. The headsign is stated once in
    // the header instead of repeating on every trip.
    final gridRows = <List<BusTimetableCell?>>[];
    for (var i = 0; i < rows.length; i += _Timetable._columns) {
      final end = i + _Timetable._columns < rows.length
          ? i + _Timetable._columns
          : rows.length;
      final chunk = rows.sublist(i, end);
      gridRows.add([
        ...chunk,
        for (var p = chunk.length; p < _Timetable._columns; p++) null,
      ]);
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppTheme.space16,
            vertical: AppTheme.space14,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: AppI18n.of(context).towardsPrefix,
                        style: AppTextStyles.bodyRegular.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                      TextSpan(
                        text: widget.headsign,
                        style: AppTextStyles.bodyRegular.copyWith(
                          fontWeight: FontWeight.w600,
                          color: cs.onSurface,
                        ),
                      ),
                    ],
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                rows.isEmpty
                    ? _dayLabel(AppI18n.of(context))
                    : AppI18n.of(context).busRunCount(rows.length),
                style: AppTextStyles.bodySmall.copyWith(
                  fontFeatures: _tnum,
                  color: cs.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        for (final gridRow in gridRows) ...[
          const DividerLine(),
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (i, cell) in gridRow.indexed) ...[
                  if (i > 0 && cell != null)
                    VerticalDivider(
                      width: 0.5,
                      thickness: 0.5,
                      color: cs.outlineVariant,
                    ),
                  Expanded(child: _cell(cell)),
                ],
              ],
            ),
          ),
        ],
        // Headway routes publish no departure times at all, so the window is
        // the whole answer; routes that publish both get it as a footer.
        for (final window in timetable.windows) ...[
          const DividerLine(),
          _HeadwayRow(window: window, cs: cs),
        ],
        if (rows.isEmpty && timetable.windows.isEmpty) ...[
          const DividerLine(),
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppTheme.space16,
              vertical: 18,
            ),
            child: Text(
              AppI18n.of(context).busNotRunningToday,
              style: AppTextStyles.bodyRegular.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _cell(BusTimetableCell? info) {
    if (info == null) return const SizedBox.shrink();
    // The next not-yet-departed trip is highlighted in place (static, per the
    // no-pulse rule): highlight fill + heavier tabular time.
    final highlight = AppTheme.surfaceHighlight(cs.brightness);
    return Container(
      color: info.isNext ? highlight : null,
      padding: const EdgeInsets.symmetric(
        vertical: AppTheme.space12,
        horizontal: AppTheme.space6,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            info.time,
            style: AppTextStyles.memo.copyWith(
              fontSize: 16,
              fontFeatures: _tnum,
              fontWeight: info.isNext ? FontWeight.w700 : FontWeight.w400,
              color: cs.onSurface,
            ),
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 14),
            child: info.isNext
                ? _tag(
                    AppI18n.of(context).busNextRun,
                    cs.onSurface,
                    FontWeight.w700,
                  )
                : info.lowFloor
                ? _tag(
                    AppI18n.of(context).busLowFloor,
                    cs.onSurfaceVariant,
                    FontWeight.w600,
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }

  Widget _tag(String text, Color color, FontWeight weight) => Text(
    text,
    style: AppTextStyles.bodySmall.copyWith(
      fontSize: 10,
      height: 1.2,
      fontWeight: weight,
      color: color,
    ),
  );
}

/// A headway-operated window on the timetable board: the service span in mono
/// so it aligns with the departure grid above it, the interval as prose.
class _HeadwayRow extends StatelessWidget {
  const _HeadwayRow({required this.window, required this.cs});
  final BusHeadwayWindow window;
  final ColorScheme cs;

  @override
  Widget build(BuildContext context) {
    // TDX sends both bounds even when they are equal; "每 15 分" is the honest
    // reading of a 15–15 range.
    final headway = window.minMins == window.maxMins
        ? AppI18n.of(context).busHeadwayFixed(window.minMins)
        : AppI18n.of(context).busHeadwayRange(window.minMins, window.maxMins);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTheme.space16,
        vertical: AppTheme.space14,
      ),
      child: Row(
        spacing: AppTheme.space12,
        children: [
          Text(
            '${window.start}–${window.end}',
            style: AppTextStyles.memo.copyWith(
              fontSize: 16,
              fontFeatures: _tnum,
              color: cs.onSurface,
            ),
          ),
          Expanded(
            child: Text(
              headway,
              style: AppTextStyles.bodyRegular.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
