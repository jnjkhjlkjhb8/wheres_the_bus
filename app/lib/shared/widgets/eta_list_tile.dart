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

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // The coming-soon highlight is achromatic: same Ink text as every other
    // row, emphasis carried by the surface-highlight background alone.
    final routeColor = muted
        ? AppTheme.inkTertiary(cs.brightness)
        : cs.onSurface;
    final destColor = muted
        ? AppTheme.inkTertiary(cs.brightness)
        : cs.onSurfaceVariant;

    final row = Row(
      children: [
        leading ??
            Text(
              routeNo,
              style: AppTextStyles.bodyLarge.copyWith(
                fontWeight: FontWeight.w700,
                color: routeColor,
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
                    AppTextStyles.bodyRegular.copyWith(color: destColor),
              ),
              if (direction != null)
                Text(
                  direction!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.bodySmall.copyWith(color: destColor),
                ),
              if (isLastBus)
                Text(
                  AppI18n.of(context).etaLastBusTag,
                  maxLines: 1,
                  style: AppTextStyles.bodySmall.copyWith(color: destColor),
                ),
            ],
          ),
        ),
        const SizedBox(width: AppTheme.space12),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            EtaValue(status: status, muted: muted),
            if (!muted && CrowdMeter.filledFor(crowdLevel) > 0) ...[
              const SizedBox(height: AppTheme.space4),
              CrowdMeter(level: crowdLevel),
            ],
          ],
        ),
      ],
    );

    // Bare mode: just the row (plus any track), so the caller owns list chrome.
    if (bare) {
      if (track == null) return row;
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          row,
          const SizedBox(height: AppTheme.space6),
          track!,
        ],
      );
    }

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
        margin: highlighted
            ? const EdgeInsets.symmetric(
                horizontal: AppTheme.space8,
                vertical: AppTheme.space6,
              )
            : EdgeInsets.zero,
        decoration: highlighted
            ? BoxDecoration(
                color: AppTheme.surfaceHighlight(cs.brightness),
                borderRadius: BorderRadius.circular(AppTheme.radiusCard),
              )
            : null,
        padding: EdgeInsets.symmetric(
          horizontal: highlighted ? AppTheme.space8 : AppTheme.space16,
          vertical: AppTheme.space10,
        ),
        child: content,
      ),
    );
  }
}

class EtaValue extends StatelessWidget {
  const EtaValue({required this.status, this.muted = false, super.key});
  final EtaStatus status;

  /// Disabled-ink rendering for service-over rows; only the label and unknown
  /// shapes can appear muted (live countdowns are never service-over).
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return switch (status) {
      EtaArriving() => Text(
        AppI18n.of(context).etaArriving,
        style: AppTextStyles.heading2.copyWith(
          fontWeight: FontWeight.w700,
          color: AppTheme.statusArrivingText,
        ),
      ),
      EtaApproaching() => Text(
        AppI18n.of(context).etaApproaching,
        style: AppTextStyles.heading2.copyWith(
          fontWeight: FontWeight.w700,
          color: AppTheme.etaApproaching,
        ),
      ),
      EtaMinutes(:final value) => Row(
        textBaseline: TextBaseline.alphabetic,
        crossAxisAlignment: CrossAxisAlignment.baseline,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$value',
            style: _bigTime(cs),
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
            style: _bigTime(cs),
          ),
          Text(
            AppI18n.of(context).goMinutesUnit,
            style: AppTextStyles.bodySmall.copyWith(color: cs.onSurfaceVariant),
          ),
          const SizedBox(width: AppTheme.space2),
          Text(
            seconds.toString().padLeft(2, '0'),
            style: _bigTime(cs),
          ),
          Text(
            AppI18n.of(context).etaSecondsUnit,
            style: AppTextStyles.bodySmall.copyWith(color: cs.onSurfaceVariant),
          ),
        ],
      ),
      EtaLabel(:final text) when _isClock(text) => Text(
        text,
        style: AppTextStyles.timeValue(
          size: muted
              ? AppTextStyles.bodyRegular.fontSize
              : AppTextStyles.heading1.fontSize,
          weight: muted ? FontWeight.w400 : AppTextStyles.heading1.fontWeight,
          color: muted ? AppTheme.inkTertiary(cs.brightness) : cs.onSurface,
        ),
      ),
      EtaLabel(:final text) => Text(
        text,
        style: AppTextStyles.bodyLarge.copyWith(
          fontWeight: muted ? FontWeight.w400 : FontWeight.w600,
          fontSize: muted ? AppTextStyles.bodyRegular.fontSize : null,
          color: muted
              ? AppTheme.inkTertiary(cs.brightness)
              : cs.onSurfaceVariant,
        ),
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
}

final _clockPattern = RegExp(r'^\d{2}:\d{2}$');
bool _isClock(String text) => _clockPattern.hasMatch(text);

/// The prominent mono time-value style (heading1 size/weight, tabular figures)
/// shared by the minute and minute+second countdowns.
TextStyle _bigTime(ColorScheme cs) => AppTextStyles.timeValue(
  size: AppTextStyles.heading1.fontSize,
  weight: AppTextStyles.heading1.fontWeight,
  color: cs.onSurface,
);
