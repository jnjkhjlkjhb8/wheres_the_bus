import 'package:flutter/material.dart';
import 'package:wheres_the_bus/app/theme/app_text_styles.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/widgets/app_button.dart';
import 'package:wheres_the_bus/shared/widgets/app_dialog.dart';
import 'package:wheres_the_bus/shared/widgets/clock_dial.dart';
import 'package:wheres_the_bus/shared/widgets/station_display_field.dart';

const _thsrStations = [
  '南港',
  '台北',
  '板橋',
  '桃園',
  '新竹',
  '苗栗',
  '台中',
  '彰化',
  '雲林',
  '嘉義',
  '台南',
  '左營',
];

Future<String?> showTHSRStationPicker(BuildContext context) {
  return showAppModal<String>(
    context: context,
    barrierLabel: AppI18n.of(context).commonChooseStation,
    builder: (_) => const _THSRPickerDialog(),
  );
}

class _THSRPickerDialog extends StatefulWidget {
  const _THSRPickerDialog();

  @override
  State<_THSRPickerDialog> createState() => _THSRPickerDialogState();
}

class _THSRPickerDialogState extends State<_THSRPickerDialog> {
  int _selectedIndex = 1;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

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
              AppI18n.of(context).commonChooseStation,
              style: AppTextStyles.bodyRegular.copyWith(
                fontWeight: FontWeight.w600,
                color: cs.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: AppTheme.space20),
            // THSR is a single flat line, so the M3 "big value above the dial"
            // is one always-selected field (no second field, no AM/PM toggle).
            StationDisplayField(
              value: _thsrStations[_selectedIndex],
              active: true,
              width: 120,
            ),
            const SizedBox(height: AppTheme.space24),
            Center(
              child: ClockDial(
                items: _thsrStations,
                selectedIndex: _selectedIndex,
                onSelected: (i) => setState(() => _selectedIndex = i),
              ),
            ),
            const SizedBox(height: AppTheme.space16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                AppButton.text(
                  label: AppI18n.of(context).commonCancel,
                  onPressed: () => Navigator.of(context).pop(),
                ),
                const SizedBox(width: AppTheme.space8),
                AppButton.text(
                  label: AppI18n.of(context).commonConfirm,
                  onPressed: () =>
                      Navigator.of(context).pop(_thsrStations[_selectedIndex]),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
