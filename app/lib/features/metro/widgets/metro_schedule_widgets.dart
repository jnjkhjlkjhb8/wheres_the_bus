part of '../view/metro_station_detail_view.dart';

class MetroScheduleSection extends StatelessWidget {
  const MetroScheduleSection({
    required this.schedule,
    this.loading = false,
    super.key,
  });

  final List<MetroSchedule> schedule;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final title = Text(
      AppI18n.of(context).metroFirstLastTrain,
      style: AppTextStyles.bodyLarge.copyWith(
        fontWeight: FontWeight.w600,
        color: cs.onSurfaceVariant,
      ),
    );

    // Both times sit in fixed columns so a value never shifts against the one
    // above it. The width follows the user's text scale, so large-text mode
    // widens the column instead of clipping the value.
    final columnWidth = MediaQuery.textScalerOf(context).scale(56);
    final hairline = cs.outlineVariant.withValues(alpha: 0.5);

    // The column headings are static text, so the loading state can show the
    // real header rather than a bone — the table is already legible before its
    // values arrive, and the header doesn't move when they do.
    final header = Row(
      // Baseline, not bottom: the labels are half the title's size, so
      // aligning boxes would leave them floating off its baseline.
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Expanded(child: title),
        _ScheduleColumnLabel(
          label: AppI18n.of(context).metroFirstTrain,
          width: columnWidth,
        ),
        _ScheduleColumnLabel(
          label: AppI18n.of(context).metroLastTrain,
          width: columnWidth,
        ),
      ],
    );

    if (loading && schedule.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          header,
          const SizedBox(height: AppTheme.space6),
          Divider(height: 1, thickness: 1, color: hairline),
          Skeletonizer(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < 2; i++) ...[
                  if (i > 0) Divider(height: 1, thickness: 1, color: hairline),
                  _ScheduleRow(
                    schedule: _skeletonSchedule,
                    columnWidth: columnWidth,
                  ),
                ],
              ],
            ),
          ),
        ],
      );
    }
    if (schedule.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          title,
          const SizedBox(height: AppTheme.space8),
          Text(
            AppI18n.of(context).metroFirstLastUnavailable,
            style: AppTextStyles.bodySmall.copyWith(
              color: cs.onSurfaceVariant,
            ),
          ),
        ],
      );
    }

    final grouped = schedule.map((s) => s.line).toSet().length > 1;

    final rows = <Widget>[];
    String? currentLine;
    for (final (i, entry) in schedule.indexed) {
      if (grouped && entry.line != currentLine) {
        currentLine = entry.line;
        rows.add(_ScheduleLineHeader(line: entry.line, first: i == 0));
      } else if (i > 0) {
        rows.add(Divider(height: 1, thickness: 1, color: hairline));
      }
      rows.add(_ScheduleRow(schedule: entry, columnWidth: columnWidth));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        header,
        const SizedBox(height: AppTheme.space6),
        Divider(height: 1, thickness: 1, color: hairline),
        ...rows,
      ],
    );
  }
}

const MetroSchedule _skeletonSchedule = MetroSchedule(
  line: '',
  destination: '囗囗囗',
  firstTime: '00:00',
  lastTime: '00:00',
);

class _ScheduleColumnLabel extends StatelessWidget {
  const _ScheduleColumnLabel({required this.label, required this.width});

  final String label;
  final double width;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // Excluded from semantics: each row announces its own 首班/末班 values, so
    // a screen reader that also read the headers would hear them twice with
    // no positional cue tying them to a value.
    return ExcludeSemantics(
      child: SizedBox(
        width: width,
        child: Text(
          label,
          textAlign: TextAlign.right,
          style: AppTextStyles.bodyVerySmall.copyWith(
            color: cs.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

/// Line divider inside the table at interchange stations: the line's roundel
/// and full name over the destinations it runs to.
class _ScheduleLineHeader extends StatelessWidget {
  const _ScheduleLineHeader({required this.line, required this.first});

  final String line;

  /// Whether this is the first group; it sits tighter under the column
  /// headers than the groups that follow a preceding block of rows.
  final bool first;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.only(
        top: first ? AppTheme.space12 : 18,
        bottom: AppTheme.space4,
      ),
      child: Row(
        children: [
          LineBadge(
            label: line,
            color: _metroLineColor(line),
            svgAsset: LineBadge.trtcAsset(line),
            size: 18,
          ),
          const SizedBox(width: 7),
          Text(
            metroLineNames(AppI18n.of(context))[line] ?? line,
            style: AppTextStyles.bodySmall.copyWith(
              color: cs.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _ScheduleRow extends StatelessWidget {
  const _ScheduleRow({required this.schedule, required this.columnWidth});

  final MetroSchedule schedule;
  final double columnWidth;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Semantics(
      label: AppI18n.of(context).metroFirstLastSemanticsFull(
        schedule.destination,
        schedule.firstTime,
        schedule.lastTime,
      ),
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 11),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Expanded(
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: AppI18n.of(context).towardsPrefix,
                      style: AppTextStyles.bodySmall.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                    TextSpan(text: schedule.destination),
                  ],
                ),
                style: AppTextStyles.bodyRegular.copyWith(
                  fontWeight: FontWeight.w600,
                  color: cs.onSurface,
                ),
              ),
            ),
            _ScheduleTime(
              time: schedule.firstTime,
              width: columnWidth,
              color: cs.onSurfaceVariant,
            ),
            _ScheduleTime(
              time: schedule.lastTime,
              width: columnWidth,
              color: cs.onSurface,
            ),
          ],
        ),
      ),
    );
  }
}

class _ScheduleTime extends StatelessWidget {
  const _ScheduleTime({
    required this.time,
    required this.width,
    required this.color,
  });

  final String time;
  final double width;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: Text(
        time,
        textAlign: TextAlign.right,
        style: AppTextStyles.timeValue(color: color),
      ),
    );
  }
}

/// Line roundel showing the line code above the station number (e.g. BR / 13),
/// filled in the line colour. Text switches to ink on light lines (e.g. Y) to
/// stay legible.
class _MetroRoundel extends StatelessWidget {
  const _MetroRoundel({required this.code});

  /// Single-line code with number, e.g. `BR14` or `G03A`.
  final String code;

  static final RegExp _split = RegExp(r'^([A-Za-z]+)(.*)$');

  @override
  Widget build(BuildContext context) {
    final match = _split.firstMatch(code);
    final letters = match?.group(1) ?? code;
    final number = match?.group(2) ?? '';
    final color = _metroLineColor(letters);
    final onColor = color.computeLuminance() > 0.5
        ? const Color(0xFF111111)
        : Colors.white;
    return Container(
      width: 30,
      height: 30,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            letters,
            textScaler: TextScaler.noScaling,
            style: TextStyle(
              fontFamily: 'IBMPlexSans',
              fontSize: 10,
              fontWeight: FontWeight.w700,
              height: 1,
              color: onColor,
            ),
          ),
          if (number.isNotEmpty)
            Text(
              number,
              textScaler: TextScaler.noScaling,
              style: TextStyle(
                fontFamily: 'IBMPlexMono',
                fontSize: 9,
                fontWeight: FontWeight.w700,
                height: 1.2,
                color: onColor,
              ),
            ),
        ],
      ),
    );
  }
}

Color _metroLineColor(String lineCode) {
  switch (lineCode) {
    case 'BL':
      return AppTheme.mrtBL;
    case 'R':
      return AppTheme.mrtR;
    case 'G':
      return AppTheme.mrtG;
    case 'O':
      return AppTheme.mrtO;
    case 'BR':
      return AppTheme.mrtBR;
    case 'Y':
      return AppTheme.mrtY;
    default:
      return AppTheme.mrtBL;
  }
}
