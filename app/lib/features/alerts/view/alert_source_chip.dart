import 'package:flutter/material.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/data/models/alert_models.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';

/// Relative time, coarsened to the buckets a rider cares about. Pure apart
/// from the strings, so it can be unit-tested against a fixed [now].
String alertRelativeTime(AppI18n i18n, DateTime time, DateTime now) {
  final diff = now.difference(time);
  if (diff.inMinutes < 1) return i18n.commonJustNow;
  if (diff.inMinutes < 60) return i18n.alertMinutesAgo(diff.inMinutes);
  if (diff.inHours < 24) return i18n.alertHoursAgo(diff.inHours);

  final today = DateTime(now.year, now.month, now.day);
  final that = DateTime(time.year, time.month, time.day);
  if (today.difference(that).inDays == 1) return i18n.commonYesterday;
  return '${time.month}/${time.day}';
}

final _cjk = RegExp('[一-鿿]');

({String label, Color color})? _resolve(
  AppI18n i18n,
  AlertSource source,
  String? department,
) {
  switch (source.kind) {
    case AlertSourceKind.metro:
      final label = switch (source.code) {
        'TRTC' => i18n.operatorTrtc,
        'TYMC' => i18n.operatorTymc,
        'KRTC' => i18n.operatorKrtc,
        'TMRT' => i18n.operatorTmrt,
        _ => source.code,
      };
      return (label: label, color: AppTheme.mrtBL);
    case AlertSourceKind.tra:
      return (label: i18n.modeTra, color: AppTheme.trainRangecar);
    case AlertSourceKind.thsr:
      return (label: i18n.modeThsr, color: AppTheme.trainThsr);
    case AlertSourceKind.busAlert:
      final label = department != null && _cjk.hasMatch(department)
          ? department
          : switch (source.code) {
              'Taipei' => i18n.operatorBusTaipei,
              'NewTaipei' => i18n.operatorBusNewTaipei,
              'Taoyuan' => i18n.operatorBusTaoyuan,
              'Taichung' => i18n.operatorBusTaichung,
              'Tainan' => i18n.operatorBusTainan,
              'Kaohsiung' => i18n.operatorBusKaohsiung,
              _ => i18n.modeBus,
            };
      // Ink carries the bus chip. In dark mode a #111111 fill would vanish, so
      // fall back to the inverse surface pair which keeps the contrast.
      return (label: label, color: AppTheme.inkLight);
    // An ops-authored announcement speaks as the app, not as an operator.
    case AlertSourceKind.appNotice:
      return (label: i18n.appName, color: AppTheme.inkLight);
  }
}

/// Compact operator tag: which system an alert belongs to, colored by operator
/// (colors are data here, not decoration). Renders nothing for a null source.
class AlertSourceChip extends StatelessWidget {
  const AlertSourceChip({required this.source, this.department, super.key});

  final AlertSource? source;

  /// TDX's own publishing department for this alert, if the feed carried one.
  final String? department;

  @override
  Widget build(BuildContext context) {
    final source = this.source;
    if (source == null) return const SizedBox.shrink();
    final resolved = _resolve(AppI18n.of(context), source, department);
    if (resolved == null) return const SizedBox.shrink();

    final cs = Theme.of(context).colorScheme;
    final dark = cs.brightness == Brightness.dark;
    // The Ink bus chip needs a dark-mode substitute; operator colors stand on
    // their own against both surfaces.
    final isInk = resolved.color == AppTheme.inkLight;
    final bg = isInk && dark ? cs.inverseSurface : resolved.color;
    final fg = isInk && dark ? cs.onInverseSurface : Colors.white;

    return Container(
      height: 20,
      padding: const EdgeInsets.symmetric(horizontal: AppTheme.space6),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        resolved.label,
        style: TextStyle(
          fontFamily: 'IBMPlexSans',
          fontSize: 11.5,
          fontWeight: FontWeight.w600,
          height: 1,
          color: fg,
        ),
      ),
    );
  }
}
