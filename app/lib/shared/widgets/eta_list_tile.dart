import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';
import 'package:wheres_the_bus/app/theme/app_text_styles.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/data/models/arrival_display.dart';
import 'package:wheres_the_bus/data/models/bus_models.dart';
import 'package:wheres_the_bus/data/models/eta_status.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/motion/pressable.dart';
import 'package:wheres_the_bus/shared/widgets/crowd_meter.dart';

export 'package:wheres_the_bus/data/models/eta_status.dart';

@Preview(name: 'EtaListTile — arriving', group: 'ETA')
@Preview(name: 'EtaListTile — minutes', group: 'ETA')
@Preview(name: 'EtaListTile — highlighted', group: 'ETA')
@Preview(name: 'EtaListTile — unknown', group: 'ETA')
Widget etaListTilePreviews() {
  return MaterialApp(
    home: Scaffold(
      body: ListView(
        children: [
          EtaListTile(
            routeNo: '307',
            destination: '板橋',
            status: EtaStatus.arriving(),
          ),
          EtaListTile(
            routeNo: '261',
            destination: '銘傳大學',
            status: EtaStatus.approaching(),
          ),
          EtaListTile(
            routeNo: '桃園106',
            destination: '中壢火車站',
            status: EtaStatus.minutes(5),
            highlighted: true,
          ),
          EtaListTile(
            routeNo: '652',
            destination: '台北車站',
            status: EtaStatus.unknown(),
          ),
        ],
      ),
    ),
  );
}

class EtaListTile extends StatelessWidget {
  const EtaListTile({
    required this.routeNo,
    required this.status,
    required this.destination,
    super.key,
    this.direction,
    this.onTap,
    this.highlighted = false,
    this.muted = false,
    this.track,
    this.leading,
    this.destinationStyle,
    this.bare = false,
    this.crowdLevel = CrowdLevel.unknown,
    this.isLastBus = false,
    this.source = EtaSource.live,
  });

  factory EtaListTile.fromDisplay(
    ArrivalDisplay display, {
    Key? key,
    String? direction,
    VoidCallback? onTap,
    bool highlighted = false,
    bool muted = false,
    Widget? track,
    Widget? leading,
    TextStyle? destinationStyle,
    bool bare = false,
  }) => EtaListTile(
    key: key,
    routeNo: display.label,
    status: display.status,
    destination: display.destination,
    direction: direction,
    onTap: onTap,
    highlighted: highlighted,
    muted: muted,
    track: track,
    leading: leading,
    destinationStyle: destinationStyle,
    bare: bare,
    crowdLevel: display.crowdLevel,
    isLastBus: display.isLastBus,
    source: display.source,
  );

  final String routeNo;
  final EtaStatus status;
  final String destination;
  final String? direction;
  final VoidCallback? onTap;
  final bool highlighted;

  /// Mutes the whole row to the disabled ink (service-over states like
  /// 末班已過 / 今日未營運), so ended rows stop competing with live ETAs.
  final bool muted;

  final Widget? track;

  /// Custom leading widget in place of the [routeNo] text (a line roundel).
  final Widget? leading;

  /// Overrides the destination text style; defaults to `bodyRegular`.
  final TextStyle? destinationStyle;

  /// When true, renders only the row (no Pressable, highlight, min-height, or
  /// padding), letting the caller own the surrounding list chrome.
  final bool bare;

  /// How full the vehicle this row describes is. Only Taipei buses carry a
  /// reading; everything else stays UNKNOWN and nothing is drawn.
  final CrowdLevel crowdLevel;

  /// Marks the row as the route's last bus of the day. Sits with the
  /// destination rather than the time: it qualifies which bus this is, and the
  /// time column stays the row's one number.
  final bool isLastBus;

  /// Non-live times drop the live emphasis and carry a 預估 qualifier.
  final EtaSource source;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final row = _row(context, cs);

    // Bare mode: just the row (plus any track), so the caller owns list chrome.
    if (bare) return _bareRow(row);

    final content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Align(alignment: Alignment.centerLeft, child: row),
        ),
        if (track != null) ...[const SizedBox(height: AppTheme.space6), track!],
      ],
    );

    return Pressable(
      onTap: onTap,
      semanticLabel: AppI18n.of(
        context,
      ).etaTowardsSemantics(routeNo, destination),
      child: Container(
        // Margin + padding sum to 16 on each side either way, so the highlight
        // tint insets without shifting the row's content off the 16px column.
        margin: _highlightMargin,
        decoration: highlighted
            ? BoxDecoration(
                color: AppTheme.surfaceHighlight(cs.brightness),
                borderRadius: BorderRadius.circular(AppTheme.radiusCard),
              )
            : null,
        padding: EdgeInsets.symmetric(
          horizontal: _horizontalPadding,
          vertical: AppTheme.space10,
        ),
        child: content,
      ),
    );
  }

  EdgeInsets get _highlightMargin => highlighted
      ? const EdgeInsets.symmetric(
          horizontal: AppTheme.space8,
          vertical: AppTheme.space6,
        )
      : EdgeInsets.zero;
  double get _horizontalPadding =>
      highlighted ? AppTheme.space8 : AppTheme.space16;

  Widget _bareRow(Widget row) {
    final detail = track;
    if (detail == null) return row;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        row,
        const SizedBox(height: AppTheme.space6),
        detail,
      ],
    );
  }

  (Color, Color) _rowColors(ColorScheme colors) => muted
      ? (
          AppTheme.inkTertiary(colors.brightness),
          AppTheme.inkTertiary(colors.brightness),
        )
      : (colors.onSurface, colors.onSurfaceVariant);

  Widget _row(BuildContext context, ColorScheme cs) {
    // Achromatic highlights carry emphasis in the surrounding surface only.
    final colors = _rowColors(cs);
    return Row(
      children: [
        leading ??
            Text(
              routeNo,
              style: AppTextStyles.bodyLarge.copyWith(
                fontWeight: FontWeight.w700,
                color: colors.$1,
              ),
            ),
        const SizedBox(width: AppTheme.space12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                AppI18n.of(context).towardsSpaced(destination),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                // A custom destination style (metro's heading2) is used
                // verbatim, keeping its own colour; the default path carries
                // the muted destination colour.
                style:
                    destinationStyle ??
                    AppTextStyles.bodyRegular.copyWith(color: colors.$2),
              ),
              if (direction != null)
                Text(
                  direction!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.bodySmall.copyWith(color: colors.$2),
                ),
              if (isLastBus)
                Text(
                  AppI18n.of(context).etaLastBusTag,
                  maxLines: 1,
                  style: AppTextStyles.bodySmall.copyWith(color: colors.$2),
                ),
            ],
          ),
        ),
        const SizedBox(width: AppTheme.space12),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            EtaValue(status: status, muted: muted, source: source),
            if (!muted && CrowdMeter.filledFor(crowdLevel) > 0) ...[
              const SizedBox(height: AppTheme.space4),
              CrowdMeter(level: crowdLevel),
            ],
          ],
        ),
      ],
    );
  }
}

class EtaValue extends StatelessWidget {
  const EtaValue({
    required this.status,
    this.muted = false,
    this.source = EtaSource.live,
    super.key,
  });
  final EtaStatus status;

  /// A scheduled or predicted time is drawn in secondary ink with a 預估
  /// qualifier, and never takes the arriving/approaching colours.
  final EtaSource source;

  /// Disabled-ink rendering for service-over rows; only the label and unknown
  /// shapes can appear muted (live countdowns are never service-over).
  final bool muted;

  bool get _estimated => !source.isLive && !muted && _carriesTime(status);

  @override
  Widget build(BuildContext context) {
    final value = _value(context);
    if (!_estimated) return value;
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        value,
        Text(
          AppI18n.of(context).etaEstimatedTag,
          style: AppTextStyles.bodySmall.copyWith(color: cs.onSurfaceVariant),
        ),
      ],
    );
  }

  Widget _value(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final live = source.isLive;
    return switch (status) {
      EtaArriving() => _statusText(
        AppI18n.of(context).etaArriving,
        cs,
        live: live,
        onDark: AppTheme.statusArriving,
        onLight: AppTheme.statusArrivingText,
      ),
      EtaApproaching() => _statusText(
        AppI18n.of(context).etaApproaching,
        cs,
        live: live,
        onDark: AppTheme.statusApproach,
        onLight: AppTheme.etaApproaching,
      ),
      EtaMinutes(:final value) => Row(
        textBaseline: TextBaseline.alphabetic,
        crossAxisAlignment: CrossAxisAlignment.baseline,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$value',
            style: _bigTime(cs, live: live),
          ),
          const SizedBox(width: AppTheme.space2),
          Text(
            AppI18n.of(context).goMinutesUnit,
            style: AppTextStyles.bodySmall.copyWith(color: cs.onSurfaceVariant),
          ),
        ],
      ),
      EtaMinutesSeconds(:final minutes, :final seconds) => Row(
        textBaseline: TextBaseline.alphabetic,
        crossAxisAlignment: CrossAxisAlignment.baseline,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$minutes',
            style: _bigTime(cs, live: live),
          ),
          Text(
            AppI18n.of(context).goMinutesUnit,
            style: AppTextStyles.bodySmall.copyWith(color: cs.onSurfaceVariant),
          ),
          const SizedBox(width: AppTheme.space2),
          Text(
            seconds.toString().padLeft(2, '0'),
            style: _bigTime(cs, live: live),
          ),
          Text(
            AppI18n.of(context).etaSecondsUnit,
            style: AppTextStyles.bodySmall.copyWith(color: cs.onSurfaceVariant),
          ),
        ],
      ),
      EtaLabel(:final text) when _isClock(text) => Text(
        text,
        style: _clockStyle(cs, live: live),
      ),
      EtaLabel(:final text) => Text(
        text,
        style: _labelStyle(cs),
      ),
      EtaUnknown() => Text(
        '—',
        semanticsLabel: AppI18n.of(context).etaNoInfo,
        style: AppTextStyles.bodyLarge.copyWith(
          color: AppTheme.inkTertiary(cs.brightness),
        ),
      ),
    };
  }

  // The light-surface greens and oranges fall under 4.5:1 on a dark sheet, so
  // the dark variants are the lighter ramp steps.
  Text _statusText(
    String text,
    ColorScheme cs, {
    required bool live,
    required Color onDark,
    required Color onLight,
  }) {
    final dark = cs.brightness == Brightness.dark;
    return Text(
      text,
      style: AppTextStyles.heading2.copyWith(
        fontWeight: FontWeight.w700,
        color: !live
            ? cs.onSurfaceVariant
            : dark
            ? onDark
            : onLight,
      ),
    );
  }

  TextStyle _clockStyle(ColorScheme cs, {required bool live}) =>
      muted ? _mutedClockStyle(cs) : _bigTime(cs, live: live);

  TextStyle _mutedClockStyle(ColorScheme cs) => AppTextStyles.timeValue(
    size: AppTextStyles.bodyRegular.fontSize,
    weight: FontWeight.w400,
    color: AppTheme.inkTertiary(cs.brightness),
  );

  TextStyle _labelStyle(ColorScheme cs) => AppTextStyles.bodyLarge.copyWith(
    fontWeight: muted ? FontWeight.w400 : FontWeight.w600,
    fontSize: muted ? AppTextStyles.bodyRegular.fontSize : null,
    color: muted ? AppTheme.inkTertiary(cs.brightness) : cs.onSurfaceVariant,
  );
}

final _clockPattern = RegExp(r'^\d{2}:\d{2}$');
bool _isClock(String text) => _clockPattern.hasMatch(text);

/// The prominent mono time-value style (heading1 size/weight, tabular figures)
/// shared by the minute and minute+second countdowns.
TextStyle _bigTime(ColorScheme cs, {required bool live}) =>
    AppTextStyles.timeValue(
      size: AppTextStyles.heading1.fontSize,
      weight: AppTextStyles.heading1.fontWeight,
      color: live ? cs.onSurface : cs.onSurfaceVariant,
    );

/// Whether [status] is a time (as opposed to a service-state word or the
/// no-data dash), the only shapes a non-live source qualifies.
bool _carriesTime(EtaStatus status) => switch (status) {
  EtaArriving() ||
  EtaApproaching() ||
  EtaMinutes() ||
  EtaMinutesSeconds() => true,
  EtaLabel(:final text) => _isClock(text),
  EtaUnknown() => false,
};
