import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/data/models/plan_models.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';

bool isWalk(PlanSection s) => s.type.toLowerCase() != 'transit';

// Walk sections carry a (non-walk) transport mode, so branch on isWalk before
// falling back to the transport mode for the glyph.
IconData sectionIcon(PlanSection s) =>
    isWalk(s) ? Icons.directions_walk_rounded : transitIcon(s.transport.mode);

IconData transitIcon(String mode) => switch (mode.toLowerCase()) {
  'walk' || 'pedestrian' => Icons.directions_walk_rounded,
  'subway' || 'metro' || 'mrt' || 'tram' => Icons.directions_subway_rounded,
  'bus' || 'highwaybus' => Icons.directions_bus_rounded,
  'rail' || 'tra' || 'train' || 'thsr' || 'hsr' => Icons.train_rounded,
  _ => Icons.directions_transit_rounded,
};

Color transitColor(PlanTransport t, ColorScheme cs) {
  final explicit = _routeColor(t.routeColor);
  if (explicit != null) return explicit;
  return _modeColor(t, cs);
}

Color? _routeColor(String color) {
  final raw = color.trim().replaceAll('#', '');
  final value = int.tryParse(raw.length == 6 ? 'FF$raw' : raw, radix: 16);
  if (value == null) return null;
  final parsed = Color(value);
  // GTFS feeds fill a missing route_color with white, which is no line
  // identity and vanishes on the map.
  return parsed.computeLuminance() > 0.9 ? null : parsed;
}

Color _modeColor(PlanTransport t, ColorScheme cs) {
  // Same mode vocabulary as transitIcon; THSR is matched before the rail
  // aliases so it keeps its own color instead of the TRA fallback.
  return switch (t.mode.toLowerCase()) {
    'walk' || 'pedestrian' => cs.onSurfaceVariant,
    'subway' || 'metro' || 'mrt' || 'tram' => AppTheme.mrtBL,
    'thsr' || 'hsr' => AppTheme.trainThsr,
    'rail' || 'tra' || 'train' => _railColor(t.category),
    'bus' || 'highwaybus' => AppTheme.markerBus,
    _ => cs.onSurface,
  };
}

Color _railColor(String category) => category.toUpperCase() == 'HSR'
    ? AppTheme.trainThsr
    : AppTheme.trainRangecar;

Color _shiftedColor(HSLColor hsl, double shift, {required bool darken}) {
  final lightness = (darken ? hsl.lightness - shift : hsl.lightness + shift)
      .clamp(0.0, 1.0);
  return hsl.withLightness(lightness).toColor();
}

Color legibleLineColor(Color line, Color background) {
  const minimumContrast = 3.0;
  if (_contrast(line, background) >= minimumContrast) return line;
  final hsl = HSLColor.fromColor(line);
  final darken = background.computeLuminance() > 0.5;
  // 2% lightness steps: fine enough that the shift is not a different colour,
  // coarse enough to settle in a couple of dozen iterations at worst.
  for (var step = 1; step <= 50; step++) {
    final shift = step * 0.02;
    final candidate = _shiftedColor(hsl, shift, darken: darken);
    if (_contrast(candidate, background) >= minimumContrast) return candidate;
  }
  // Darkening reaches black at step 50, which always clears the bar, so only
  // the lightening direction can exhaust the loop.
  return Colors.white;
}

double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

String sectionLabel(AppI18n i18n, PlanSection s) {
  final t = s.transport;
  if (isWalk(s)) return i18n.goWalk;
  final name = t.shortName.isNotEmpty ? t.shortName : t.name;
  return name;
}

String minutesLabel(AppI18n i18n, int minutes) => i18n.minutesValue(minutes);

int sectionMinutes(PlanSection s) {
  final secs = s.travelSummary.duration;
  return (secs / 60).round().clamp(0, 999);
}
