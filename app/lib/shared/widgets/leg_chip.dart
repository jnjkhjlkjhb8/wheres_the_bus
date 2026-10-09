import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:wheres_the_bus/app/theme/app_text_styles.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/data/models/plan_models.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';

class LegChip extends StatelessWidget {
  const LegChip({required this.section, required this.duration, super.key});

  final PlanSection section;
  final Duration duration;

  static String _modeKey(PlanSection s) => s.transport.mode.toLowerCase();

  static String? _mrtSvg(PlanSection s) {
    const map = {
      'BL': 'assets/mrt/BL.svg',
      'R': 'assets/mrt/R.svg',
      'G': 'assets/mrt/G.svg',
      'O': 'assets/mrt/O.svg',
      'BR': 'assets/mrt/BR.svg',
      'Y': 'assets/mrt/Y.svg',
    };
    final line = s.transport.shortName.toUpperCase();
    for (final e in map.entries) {
      if (line.startsWith(e.key)) return e.value;
    }
    return null;
  }

  static String _durationLabel(AppI18n i18n, Duration d) {
    if (d.inHours > 0) return '${d.inHours}h${d.inMinutes.remainder(60)}m';
    return i18n.minutesTight(d.inMinutes);
  }

  @override
  Widget build(BuildContext context) {
    final mode = _modeKey(section);
    final label = _durationLabel(AppI18n.of(context), duration);

    Widget icon;

    if (mode == 'walk') {
      icon = const Icon(
        Icons.directions_walk_rounded,
        size: 24,
        color: Colors.grey,
      );
    } else if (mode == 'subway' || mode == 'tram') {
      final svg = _mrtSvg(section);
      icon = svg != null
          ? SvgPicture.asset(svg, width: 45, height: 45)
          : const Icon(Icons.directions_subway, size: 45);
    } else if (mode == 'rail' && section.transport.category == 'HSR') {
      icon = SvgPicture.asset(
        'assets/rails/thsr_logo.svg',
        width: 70,
        height: 45,
      );
    } else if (mode == 'bus') {
      icon = _BusIconWithBadge(shortName: section.transport.shortName);
    } else {
      icon = Icon(
        Icons.directions_transit_filled_rounded,
        size: 24,
        color: Theme.of(context).colorScheme.primary,
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        icon,
        const SizedBox(height: AppTheme.space2),
        Text(label, style: AppTextStyles.bodyVerySmall),
      ],
    );
  }
}

class _BusIconWithBadge extends StatelessWidget {
  const _BusIconWithBadge({required this.shortName});
  final String shortName;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        const Icon(Icons.directions_bus_rounded, size: 24),
        Positioned(
          right: -6,
          bottom: -4,
          child: Container(
            padding: const EdgeInsets.all(AppTheme.space2),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(AppTheme.radiusChip),
              border: Border.all(color: cs.outline, width: 0.5),
            ),
            child: Text(
              shortName,
              style: AppTextStyles.bodyVerySmall.copyWith(color: cs.outline),
            ),
          ),
        ),
      ],
    );
  }
}
