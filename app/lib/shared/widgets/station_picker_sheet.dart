import 'package:flutter/material.dart';
import 'package:smooth_sheets/smooth_sheets.dart';
import 'package:wheres_the_bus/app/theme/app_text_styles.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/motion/pressable.dart';
import 'package:wheres_the_bus/shared/widgets/app_search_bar.dart';
import 'package:wheres_the_bus/shared/widgets/bottom_sheet_shell.dart';

class StationPickerSheet extends StatefulWidget {
  const StationPickerSheet({required this.stations, super.key});

  final List<String> stations;

  static Future<String?> show(BuildContext context, List<String> stations) {
    return BottomSheetShell.show<String>(
      context: context,
      initialOffset: const SheetOffset.proportionalToViewport(0.6),
      child: Expanded(child: StationPickerSheet(stations: stations)),
    );
  }

  @override
  State<StationPickerSheet> createState() => _StationPickerSheetState();
}

class _StationPickerSheetState extends State<StationPickerSheet> {
  var _query = '';

  @override
  Widget build(BuildContext context) {
    final filtered = widget.stations.where((s) => s.contains(_query)).toList();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppTheme.space16,
            AppTheme.space8,
            AppTheme.space16,
            AppTheme.space8,
          ),
          child: AppSearchBar(
            hintText: AppI18n.of(context).commonSearchStation,
            autofocus: true,
            onChanged: (v) => setState(() => _query = v),
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: filtered.length,
            itemBuilder: (_, i) => Pressable(
              onTap: () => Navigator.of(context).pop(filtered[i]),
              semanticLabel: filtered[i],
              child: ListTile(
                title: Text(filtered[i], style: AppTextStyles.bodyLarge),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
