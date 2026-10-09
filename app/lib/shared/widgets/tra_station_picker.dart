import 'dart:async';

import 'package:flutter/material.dart';
import 'package:wheres_the_bus/app/theme/app_text_styles.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/core/storage/hive_store.dart';
import 'package:wheres_the_bus/data/models/tra_stations.dart';
import 'package:wheres_the_bus/shared/motion/app_motion.dart';
import 'package:wheres_the_bus/shared/motion/pressable.dart';
import 'package:wheres_the_bus/shared/widgets/app_button.dart';
import 'package:wheres_the_bus/shared/widgets/app_dialog.dart';
import 'package:wheres_the_bus/shared/widgets/clock_dial.dart';
import 'package:wheres_the_bus/shared/widgets/station_display_field.dart';

Future<String?> showTRAStationPicker(BuildContext context) {
  return showAppModal<String>(
    context: context,
    barrierLabel: '選擇車站',
    builder: (_) => const _TRAPickerDialog(),
  );
}

class _TRAPickerDialog extends StatefulWidget {
  const _TRAPickerDialog();

  @override
  State<_TRAPickerDialog> createState() => _TRAPickerDialogState();
}

class _TRAPickerDialogState extends State<_TRAPickerDialog> {
  // Reopens on the half last used. An unknown stored value (data reshaped
  // since it was written) falls back rather than throwing on the lookup.
  String _hemisphere = TraStations.data.containsKey(HiveStore.traHemisphere)
      ? HiveStore.traHemisphere!
      : '北部';
  int _regionIndex = 0;
  int _stationIndex = 0;
  bool _stationTile = false;

  List<String> get _regions => TraStations.data[_hemisphere]!.keys.toList();

  String get _region => _regions[_regionIndex.clamp(0, _regions.length - 1)];

  List<String> get _stations => TraStations.data[_hemisphere]![_region]!;

  String get _station =>
      _stations[_stationIndex.clamp(0, _stations.length - 1)];

  List<String> get _activeItems => _stationTile ? _stations : _regions;

  int get _activeIndex => _stationTile ? _stationIndex : _regionIndex;

  void _onDialSelected(int idx) {
    setState(() {
      if (_stationTile) {
        _stationIndex = idx;
      } else {
        _regionIndex = idx;
        _stationIndex = 0;
      }
    });
  }

  // Region → station is a two-step flow: releasing the dial after picking a
  // region advances to station select. Releasing in station mode does nothing
  // (the station tap on the region tile is how you go back to fix the region).
  void _onDialReleased() {
    if (!_stationTile) {
      setState(() => _stationTile = true);
    }
  }

  void _selectTile(bool station) {
    setState(() => _stationTile = station);
  }

  void _setHemisphere(String h) {
    unawaited(HiveStore.setTraHemisphere(h));
    setState(() {
      _hemisphere = h;
      _regionIndex = 0;
      _stationIndex = 0;
      _stationTile = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final motion = !AppMotion.reduced(context);

    return Dialog(
      backgroundColor: cs.surfaceContainerHigh,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTheme.radiusModal),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppTheme.space24,
          AppTheme.space24,
          AppTheme.space24,
          AppTheme.space16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '選擇車站',
              style: AppTextStyles.bodyRegular.copyWith(
                fontWeight: FontWeight.w600,
                color: cs.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: AppTheme.space20),
            _header(cs, motion),
            const SizedBox(height: AppTheme.space24),
            Center(
              child: ClockDial(
                items: _activeItems,
                selectedIndex: _activeIndex,
                onSelected: _onDialSelected,
                onReleased: _onDialReleased,
              ),
            ),
            const SizedBox(height: AppTheme.space16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                AppButton.text(
                  label: '取消',
                  onPressed: () => Navigator.of(context).pop(),
                ),
                const SizedBox(width: AppTheme.space8),
                AppButton.text(
                  label: '確定',
                  onPressed: () => Navigator.of(context).pop(_station),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _header(ColorScheme cs, bool motion) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Row(
          children: [
            StationDisplayField(
              value: _region,
              active: !_stationTile,
              onTap: () => _selectTile(false),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppTheme.space6),
              child: Text(
                ':',
                style: TextStyle(
                  fontSize: 36,
                  fontWeight: FontWeight.w400,
                  color: cs.onSurfaceVariant,
                ),
              ),
            ),
            StationDisplayField(
              value: _station,
              active: _stationTile,
              onTap: () => _selectTile(true),
            ),
          ],
        ),
        _hemisphereToggle(cs, motion),
      ],
    );
  }

  Widget _hemisphereToggle(ColorScheme cs, bool motion) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: cs.outline),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: ['北部', '南部'].asMap().entries.map((e) {
          final h = e.value;
          final active = h == _hemisphere;
          return AnimatedContainer(
            duration: motion ? AppMotion.micro : Duration.zero,
            curve: AppMotion.easeOut,
            decoration: BoxDecoration(
              color: active ? cs.tertiaryContainer : null,
              border: e.key == 0
                  ? Border(bottom: BorderSide(color: cs.outline))
                  : null,
            ),
            // Two cells stack to the field height (76) so the toggle's baseline
            // lines up with the value fields, as M3's AM/PM does.
            child: Pressable(
              onTap: () => _setHemisphere(h),
              semanticLabel: h,
              child: SizedBox(
                width: 52,
                height: 38,
                child: Center(
                  child: Text(
                    h,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: active
                          ? cs.onTertiaryContainer
                          : cs.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}
