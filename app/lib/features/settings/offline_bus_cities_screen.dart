import 'dart:async';

import 'package:flutter/material.dart';
import 'package:wheres_the_bus/app/theme/app_text_styles.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/core/firebase/crash_reporter.dart';
import 'package:wheres_the_bus/core/haptics/haptic_service.dart';
import 'package:wheres_the_bus/core/storage/hive_store.dart';
import 'package:wheres_the_bus/data/models/city_names.dart';
import 'package:wheres_the_bus/data/repositories/offline_bus_cities.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/motion/pressable.dart';
import 'package:wheres_the_bus/shared/widgets/app_bars.dart';
import 'package:wheres_the_bus/shared/widgets/app_card.dart';

/// Every `bus_static.city` value, north to south (ADR-0029).
const List<String> kOfflineBusCities = [
  'Keelung', 'Taipei', 'NewTaipei', 'Taoyuan', 'Hsinchu', 'HsinchuCounty', //
  'MiaoliCounty', 'Taichung', 'ChanghuaCounty', 'NantouCounty', //
  'YunlinCounty', 'Chiayi', 'ChiayiCounty', 'Tainan', 'Kaohsiung', //
  'PingtungCounty', 'YilanCounty', 'HualienCounty', 'TaitungCounty', //
  'PenghuCounty', 'KinmenCounty', 'InterCity',
];

/// Picks the cities whose bus routes stay available offline. Cities the app
/// adds on its own (nearest stop, favourites) show as included with a note
/// and need no tap.
class OfflineBusCitiesScreen extends StatefulWidget {
  const OfflineBusCitiesScreen({super.key, this.refresh});

  /// Applies the new choice; defaults to [refreshOfflineBusCities].
  final Future<void> Function()? refresh;

  @override
  State<OfflineBusCitiesScreen> createState() => _OfflineBusCitiesScreenState();
}

class _OfflineBusCitiesScreenState extends State<OfflineBusCitiesScreen> {
  late Set<String> _chosen = HiveStore.chosenOfflineBusCities.toSet();
  late final Set<String> _inferred = HiveStore.offlineBusCities.toSet()
    ..removeAll(_chosen);

  Future<void> _toggle(String city) async {
    unawaited(HapticService.instance.selectionClick());
    final next = {..._chosen};
    if (!next.remove(city)) next.add(city);
    setState(() => _chosen = next);
    await HiveStore.setChosenOfflineBusCities(next.toList()..sort());
    await (widget.refresh ?? refreshOfflineBusCities)().catchError(
      CrashReporter.record,
    );
  }

  bool _includes(String city) =>
      _chosen.contains(city) || _inferred.contains(city);

  /// Marks a city the app added on its own, until the rider picks it too.
  String? _noteFor(String city, String note) =>
      _inferred.contains(city) && !_chosen.contains(city) ? note : null;

  @override
  Widget build(BuildContext context) {
    final i18n = AppI18n.of(context);
    return Scaffold(
      appBar: DetailAppBar(title: i18n.settingsOfflineBus),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          AppTheme.space16,
          0,
          AppTheme.space16,
          AppTheme.space16,
        ),
        children: [
          AppCard.outlined(
            padding: const EdgeInsets.symmetric(horizontal: AppTheme.space16),
            child: Column(
              children: [
                for (final city in kOfflineBusCities)
                  _CityRow(
                    label: cityName(city),
                    included: _includes(city),
                    note: _noteFor(city, i18n.settingsOfflineBusAutomatic),
                    onTap: () => _toggle(city),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(AppTheme.space12),
            child: Text(
              i18n.settingsOfflineBusFooter,
              style: AppTextStyles.bodySmall.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CityRow extends StatelessWidget {
  const _CityRow({
    required this.label,
    required this.included,
    required this.note,
    required this.onTap,
  });

  final String label;
  final bool included;
  final String? note;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // Min-height, not fixed, so a large text scale grows the row.
    return Semantics(
      selected: included,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 44),
        child: Pressable(
          onTap: onTap,
          semanticLabel: [label, ?note].join(', '),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: AppTheme.space10),
            child: Row(
              children: [
                Expanded(child: Text(label, style: AppTextStyles.bodyLarge)),
                if (note case final note?)
                  Text(
                    note,
                    style: AppTextStyles.bodySmall.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                const SizedBox(width: AppTheme.space8),
                Visibility.maintain(
                  visible: included,
                  child: const Icon(Icons.check_rounded, size: 20),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
