import 'package:flutter/material.dart';

abstract final class SavedPlaceIcons {
  static const fallback = 'place';

  static const Map<String, IconData> _icons = {
    'home': Icons.home_rounded,
    'work': Icons.work_outline_rounded,
    'school': Icons.school_rounded,
    'star': Icons.star_rounded,
    'place': Icons.place_rounded,
    'restaurant': Icons.restaurant_rounded,
    'shopping': Icons.shopping_bag_rounded,
    'fitness': Icons.fitness_center_rounded,
    'hospital': Icons.local_hospital_rounded,
  };

  /// The ordered keys, for laying out the picker.
  static List<String> get keys => _icons.keys.toList(growable: false);

  /// The [IconData] for [key], falling back to the [fallback] glyph when the
  /// key is unknown.
  static IconData resolve(String? key) => _icons[key] ?? _icons[fallback]!;
}
