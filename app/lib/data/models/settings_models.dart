import 'package:flutter/widgets.dart';

/// Presentation data for one settings row.
class SettingsItemData {
  const SettingsItemData({
    required this.label,
    required this.value,
    required this.icon,
  });

  final String label;

  final String value;

  final IconData icon;
}

/// Presentation data for a group of settings rows.
class SettingsGroupData {
  const SettingsGroupData({
    required this.title,
    required this.items,
  });

  final String title;

  final List<SettingsItemData> items;
}
