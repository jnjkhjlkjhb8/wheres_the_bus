part of '../view/rail_screen.dart';

class _Cols {
  const _Cols._();

  static const depart = 74.0;

  static const arrive = 52.0;

  static const number = 36.0;

  static const markLine = 17.0;

  /// Scaled so the slots still fit their text in the app's large-text mode,
  /// where a fixed pixel width would clip the digits it was sized around.
  static double scaled(BuildContext context, double base) =>
      MediaQuery.textScalerOf(context).scale(base);
}

class _TrainRow extends StatelessWidget {
  const _TrainRow({
    required this.row,
    required this.system,
    required this.date,
    required this.origin,
    required this.destination,
    required this.isNext,
    required this.minutesUntil,
  });

  final _RailRow row;
  final RailSystem system;
  final String date;
  final String origin;
  final String destination;

  /// The first departure still to come today. Marked with weight and size
  /// only — no pulsing, per the design system's coming-soon rule.
  final bool isNext;

  /// Minutes until departure, or null when the query is not for today and a
  /// countdown would be meaningless.
  final int? minutesUntil;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // A suspended train still occupies its slot in the timetable — dropping it
    // would leave an unexplained gap where the user expects a train — but it
    // must never read as a candidate, so the whole row goes quiet.
    final suspended = row.isSuspended;
    final timeColor = suspended
        ? AppTheme.inkTertiary(cs.brightness)
        : cs.onSurface;

    return Pressable(
      onTap: () {
        unawaited(
          context.push(
            AppRoutes.railTrain(
              row.number,
              system: system,
              date: DateTime.tryParse(date),
            ),
            // The location names the train; everything below is context only
            // this list holds, so it rides warm and a cold link goes without.
            extra: RailTrainExtra(
              typeLabel: row.type,
              // Carry the searched O/D through so the detail screen prices
              // and highlights the segment this row quoted, rather than the
              // train's full run — the two screens must not disagree.
              userOrigin: origin,
              userDest: destination,
              // 追蹤 lives in the detail screen's app bar; it needs the live
              // delay to offset the countdown, and only this list holds it.
              delayMinutes: row.delay,
              // Neither travels on the stop-times RPC the detail screen
              // calls, so they ride along from the timetable that has them.
              marks: row.marks,
              remark: row.remark,
            ),
          ),
        );
      },
      semanticLabel: _semanticLabel(AppI18n.of(context)),
      child: Container(
        color: isNext ? cs.surfaceContainerHighest : cs.surfaceContainerLow,
        padding: EdgeInsets.symmetric(
          horizontal: AppTheme.space16,
          vertical: isNext ? 13 : 11,
        ),
        child: Row(
          children: [
            SizedBox(
              width: _Cols.scaled(context, _Cols.depart),
              child: _DepartureColumn(
                time: row.depart,
                color: timeColor,
                emphasised: isNext,
                struck: suspended,
                footnote: _Footnote.of(
                  AppI18n.of(context),
                  row,
                  minutesUntil: isNext ? minutesUntil : null,
                ),
              ),
            ),
            const SizedBox(width: AppTheme.space8),
            Expanded(
              child: _DurationConnector(
                duration: row.duration,
                emphasised: isNext,
                dimmed: suspended,
              ),
            ),
            const SizedBox(width: AppTheme.space8),
            SizedBox(
              width: _Cols.scaled(context, _Cols.arrive),
              child: Text(
                row.arrive,
                textAlign: TextAlign.right,
                style: AppTextStyles.timeValue(
                  size: 15,
                  weight: FontWeight.w500,
                  color: suspended
                      ? AppTheme.inkTertiary(cs.brightness)
                      : cs.onSurfaceVariant,
                  decoration: suspended ? TextDecoration.lineThrough : null,
                ),
              ),
            ),
            const SizedBox(width: AppTheme.space10),
            _TrainIdentity(row: row, dimmed: suspended),
          ],
        ),
      ),
    );
  }

  String _semanticLabel(AppI18n i18n) {
    final parts = <String>[
      '${TrainTypeChip.canonicalLabel(i18n, row.type)} ${row.number}',
      i18n.railDepartsFrom(origin, row.depart),
      i18n.railArrivesAt(destination, row.arrive),
      if (row.duration.isNotEmpty) i18n.railRunsFor(row.duration),
      if (row.isSuspended) i18n.railSuspended,
      if (row.isAddedService) i18n.railExtraService,
      if (row.delay > 0) i18n.railDelayMinutes(row.delay),
      if (isNext && minutesUntil != null) i18n.railDepartsIn(minutesUntil!),
      for (final mark in row.marks) mark.labelOf(i18n),
    ];
    return parts.join('，');
  }
}

/// The departure time and whatever qualifies it — a countdown, a delay, or a
/// state word. All three modify this specific time, so they sit under it
/// rather than beside the train number where they would read as a type label.
class _DepartureColumn extends StatelessWidget {
  const _DepartureColumn({
    required this.time,
    required this.color,
    required this.emphasised,
    required this.struck,
    required this.footnote,
  });

  final String time;
  final Color color;
  final bool emphasised;
  final bool struck;
  final _Footnote? footnote;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          time,
          style: AppTextStyles.timeValue(
            size: emphasised ? 24 : 21,
            weight: emphasised ? FontWeight.w700 : FontWeight.w600,
            color: color,
            letterSpacing: -0.4,
            decoration: struck ? TextDecoration.lineThrough : null,
          ),
        ),
        if (footnote != null) ...[
          const SizedBox(height: 1),
          Text(
            footnote!.text,
            style: AppTextStyles.bodyVerySmall.copyWith(
              color: footnote!.color(Theme.of(context).colorScheme),
              fontWeight: FontWeight.w600,
              height: 1.2,
            ),
          ),
        ],
      ],
    );
  }
}

/// What qualifies a departure time, in the order it matters: a cancelled train
/// cannot be late, and a late train's delay outranks its countdown.
class _Footnote {
  const _Footnote(this.text, this._tone);

  final String text;
  final _FootnoteTone _tone;

  Color color(ColorScheme cs) => switch (_tone) {
    _FootnoteTone.critical => cs.error,
    _FootnoteTone.neutral => cs.onSurfaceVariant,
    _FootnoteTone.emphasis => cs.onSurface,
  };

  static _Footnote? of(AppI18n i18n, _RailRow row, {int? minutesUntil}) {
    if (row.isSuspended) {
      return _Footnote(i18n.railSuspendedShort, _FootnoteTone.critical);
    }
    if (row.delay > 0) {
      return _Footnote(
        i18n.railDelayMinutes(row.delay),
        _FootnoteTone.critical,
      );
    }
    // Past an hour the countdown stops being a countdown — "177 分後" is
    // arithmetic the departure time above it already answered better. The row
    // keeps its emphasis (it is still the next train) and drops the number.
    if (minutesUntil != null && minutesUntil <= 60) {
      // Under a minute the countdown would flicker between "1 分後" and "0
      // 分後" while the train is effectively at the platform; say so instead.
      return _Footnote(
        minutesUntil < 1
            ? i18n.railDepartingSoon
            : i18n.railInMinutes(minutesUntil),
        _FootnoteTone.emphasis,
      );
    }
    if (row.isAddedService) {
      return _Footnote(i18n.railExtraService, _FootnoteTone.neutral);
    }
    return null;
  }
}

enum _FootnoteTone { critical, neutral, emphasis }

class _DurationConnector extends StatelessWidget {
  const _DurationConnector({
    required this.duration,
    required this.emphasised,
    required this.dimmed,
  });

  final String duration;
  final bool emphasised;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final lineColor = dimmed
        ? cs.outlineVariant
        : (emphasised ? cs.onSurfaceVariant : cs.outlineVariant);
    final line = Expanded(child: Container(height: 1, color: lineColor));

    if (duration.isEmpty) return Row(children: [line]);

    return Row(
      children: [
        line,
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppTheme.space6),
          child: Text(
            duration,
            style: AppTextStyles.timeValue(
              size: 11,
              color: dimmed
                  ? AppTheme.inkTertiary(cs.brightness)
                  : cs.onSurfaceVariant,
            ),
          ),
        ),
        line,
      ],
    );
  }
}

/// Column headings for the timetable. Names the two time columns, which is
/// what stops a reader from having to work out from context whether the left
/// number is a departure or an arrival.
class _TimetableHeader extends StatelessWidget {
  const _TimetableHeader();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final style = AppTextStyles.bodyVerySmall.copyWith(
      color: cs.onSurfaceVariant,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.4,
    );

    return Container(
      // Carries the same surface as the rows below so the list reads as one
      // continuous table rather than a heading floating above a separate one.
      color: cs.surfaceContainerLow,
      padding: const EdgeInsets.fromLTRB(
        AppTheme.space16,
        11,
        AppTheme.space16,
        9,
      ),
      child: Row(
        children: [
          SizedBox(
            width: _Cols.scaled(context, _Cols.depart),
            child: Text(AppI18n.of(context).railColDepart, style: style),
          ),
          const Spacer(),
          SizedBox(
            width: _Cols.scaled(context, _Cols.arrive),
            child: Text(
              AppI18n.of(context).railColArrive,
              textAlign: TextAlign.right,
              style: style,
            ),
          ),
          const SizedBox(width: AppTheme.space10),
          SizedBox(
            width: _Cols.scaled(context, _Cols.number),
            child: Text(
              AppI18n.of(context).railColTrainNo,
              textAlign: TextAlign.right,
              style: style,
            ),
          ),
          const SizedBox(width: AppTheme.space6),
          // Reserves the train-type chip's slot so the heading above the
          // number column lines up with the numbers rather than with the chip.
          const Opacity(
            opacity: 0,
            child: TrainTypeChip(type: '區間車', compact: true),
          ),
        ],
      ),
    );
  }
}

class _TrainIdentity extends StatelessWidget {
  const _TrainIdentity({required this.row, required this.dimmed});

  final _RailRow row;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: _Cols.scaled(context, _Cols.number),
              child: Text(
                row.number,
                textAlign: TextAlign.right,
                style: AppTextStyles.timeValue(
                  size: 12,
                  color: dimmed
                      ? AppTheme.inkTertiary(cs.brightness)
                      : cs.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(width: AppTheme.space6),
            // A suspended train's type still identifies it, but the operator
            // colour would make the row look like a live option; grey it.
            Opacity(
              opacity: dimmed ? 0.45 : 1,
              child: TrainTypeChip(type: row.type, compact: true),
            ),
          ],
        ),
        SizedBox(
          height: _Cols.scaled(context, _Cols.markLine),
          child: dimmed
              ? null
              : Align(
                  alignment: Alignment.bottomRight,
                  child: RailServiceMarkRow(marks: row.marks),
                ),
        ),
      ],
    );
  }
}
