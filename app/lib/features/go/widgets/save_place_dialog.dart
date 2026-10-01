import 'dart:async';

import 'package:flutter/material.dart';
import 'package:wheres_the_bus/app/theme/app_text_styles.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/core/haptics/haptic_service.dart';
import 'package:wheres_the_bus/features/go/model/saved_place_icons.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/motion/pressable.dart';
import 'package:wheres_the_bus/shared/widgets/app_button.dart';
import 'package:wheres_the_bus/shared/widgets/app_dialog.dart';

/// Centered modal to name a saved place and pick its icon. Returns the chosen
/// `(name, iconKey)` on 儲存, or null on cancel/dismiss.
Future<({String name, String iconKey})?> showSavePlaceDialog(
  BuildContext context, {
  required String initialName,
  String? initialIcon,
}) {
  return showDialog<({String name, String iconKey})>(
    context: context,
    builder: (_) =>
        _SavePlaceDialog(initialName: initialName, initialIcon: initialIcon),
  );
}

class _SavePlaceDialog extends StatefulWidget {
  const _SavePlaceDialog({required this.initialName, this.initialIcon});

  final String initialName;
  final String? initialIcon;

  @override
  State<_SavePlaceDialog> createState() => _SavePlaceDialogState();
}

class _SavePlaceDialogState extends State<_SavePlaceDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.initialName,
  );
  late String _icon = widget.initialIcon ?? SavedPlaceIcons.keys.first;

  @override
  void initState() {
    super.initState();
    _name.addListener(_onNameChanged);
  }

  @override
  void dispose() {
    _name
      ..removeListener(_onNameChanged)
      ..dispose();
    super.dispose();
  }

  // Rebuilds only to toggle the 儲存 button's enabled state as the name
  // field crosses the empty/non-empty boundary.
  void _onNameChanged() => setState(() {});

  void _submit() {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    unawaited(HapticService.instance.lightTap());
    Navigator.of(context).pop((name: name, iconKey: _icon));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AppDialog(
      title: AppI18n.of(context).goSavedPlaces,
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            AppI18n.of(context).commonName,
            style: AppTextStyles.bodySmall.copyWith(
              color: cs.onSurfaceVariant,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: AppTheme.space8),
          TextField(
            controller: _name,
            autofocus: true,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _submit(),
            style: AppTextStyles.bodyLarge.copyWith(
              color: cs.onSurface,
              fontWeight: FontWeight.w600,
            ),
            decoration: InputDecoration(
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: AppTheme.space14,
                vertical: AppTheme.space12,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppTheme.radiusButton),
                borderSide: BorderSide(color: cs.outlineVariant),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppTheme.radiusButton),
                borderSide: BorderSide(color: cs.onSurface, width: 2),
              ),
            ),
          ),
          const SizedBox(height: 18),
          Text(
            AppI18n.of(context).commonIcon,
            style: AppTextStyles.bodySmall.copyWith(
              color: cs.onSurfaceVariant,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: AppTheme.space10),
          _IconGrid(
            selected: _icon,
            onSelect: (key) => setState(() => _icon = key),
          ),
          const SizedBox(height: AppTheme.space20),
          Row(
            children: [
              Expanded(
                child: AppButton.outlined(
                  label: AppI18n.of(context).commonCancel,
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ),
              const SizedBox(width: AppTheme.space12),
              Expanded(
                child: AppButton(
                  label: AppI18n.of(context).commonSave,
                  onPressed: _name.text.trim().isEmpty ? null : _submit,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _IconGrid extends StatelessWidget {
  const _IconGrid({required this.selected, required this.onSelect});

  final String selected;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Wrap(
      spacing: AppTheme.space10,
      runSpacing: AppTheme.space10,
      children: [
        for (final key in SavedPlaceIcons.keys)
          Pressable(
            onTap: () => onSelect(key),
            semanticLabel: key,
            child: Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: key == selected
                    ? cs.surface
                    : cs.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(AppTheme.radiusCard),
                border: Border.all(
                  color: key == selected ? cs.onSurface : Colors.transparent,
                  width: 1.5,
                ),
              ),
              child: Icon(
                SavedPlaceIcons.resolve(key),
                size: 22,
                color: key == selected ? cs.onSurface : cs.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }
}
