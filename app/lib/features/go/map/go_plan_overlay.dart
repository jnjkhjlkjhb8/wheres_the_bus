import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:wheres_the_bus/data/models/plan_models.dart';
import 'package:wheres_the_bus/features/go/widgets/transit_visuals.dart';
import 'package:wheres_the_bus/shared/map/marker_factory.dart';

/// Muted grey for the alternate routes: present enough to tap, quiet enough
/// that the selected route reads as the answer.
const kAltRouteColor = Color(0xFF9AA0A6);

/// One layer handed to the `GoogleMap`.
typedef GoMapLayer = ({Set<Marker> markers, Set<Polyline> polylines});

class GoPlanOverlay {
  GoPlanOverlay({
    required this.onAlternateTap,
    required this.onPuckTap,
    required this.onBitmapReady,
  });

  /// Tapping one of the muted alternate routes; the screen previews it.
  final void Function(int routeIndex) onAlternateTap;

  /// Tapping the navigation puck; the screen re-arms follow and recenters.
  final VoidCallback onPuckTap;

  /// A pending bitmap finished rendering and the layer should be rebuilt. The
  /// screen turns this into a repaint; the memo has already been dropped.
  final VoidCallback onBitmapReady;

  final _markerCache = <String, BitmapDescriptor>{};
  final _pending = <String>{};

  // Memo inputs. The layer is rebuilt only when one of them actually moves;
  // an identical frame reuses the sets rather than re-deriving every polyline
  // on a camera tick.
  PlanResult? _memoResult;
  int? _memoSelected;
  int? _memoLeg;
  ColorScheme? _memoScheme;
  Set<Polyline> _memoPolylines = const {};
  Set<Marker> _memoMarkers = const {};

  bool _disposed = false;

  /// Drops every cached bitmap. The screen calls this on a theme flip, which
  /// changes every rendered marker without changing the plan they belong to.
  void invalidate() {
    _markerCache.clear();
    _pending.clear();
    _memoResult = null;
  }

  /// Stops pending bitmap callbacks from firing after the screen is gone.
  void dispose() => _disposed = true;

  GoMapLayer forPlan({
    required PlanResult result,
    required int selectedIndex,
    required ColorScheme colors,
    int? activeLeg,
    LatLng? fix,
    double puckHeading = 0,
  }) {
    if (!identical(_memoResult, result) ||
        _memoSelected != selectedIndex ||
        _memoLeg != activeLeg ||
        !identical(_memoScheme, colors)) {
      _memoResult = result;
      _memoSelected = selectedIndex;
      _memoLeg = activeLeg;
      _memoScheme = colors;
      _memoPolylines = _planPolylines(
        result,
        selectedIndex,
        activeLeg,
        colors,
      );
      _memoMarkers = _planMarkers(
        result.routes[selectedIndex],
        activeLeg,
        colors,
      );
    }

    // The puck is deliberately outside the memo: it moves on every fix and
    // every applied heading, which is far more often than the plan changes.
    final puck = _navPuck(colors, fix: fix, heading: puckHeading);
    return (
      markers: puck == null ? _memoMarkers : {..._memoMarkers, puck},
      polylines: _memoPolylines,
    );
  }

  GoMapLayer pending({
    required LatLng? origin,
    required LatLng? destination,
    required ColorScheme colors,
  }) {
    if (origin == null || destination == null) {
      return (markers: const {}, polylines: const {});
    }
    final originIcon = _originMarker(colors, dim: false);
    final destIcon = _destMarker(colors, dim: false);
    return (
      markers: {
        if (originIcon != null)
          Marker(
            markerId: const MarkerId('pending_origin'),
            position: origin,
            icon: originIcon,
            anchor: const Offset(0.5, 0.5),
          ),
        if (destIcon != null)
          Marker(
            markerId: const MarkerId('pending_dest'),
            position: destination,
            icon: destIcon,
            anchor: const Offset(0.5, 0.5),
          ),
      },
      polylines: {
        Polyline(
          polylineId: const PolylineId('pending_direct'),
          points: [origin, destination],
          width: 3,
          color: colors.onSurface.withValues(alpha: 0.45),
          patterns: [PatternItem.dot, PatternItem.gap(14)],
        ),
      },
    );
  }

  // ── polylines ─────────────────────────────────────────────────────────────

  /// Every route on the map: muted single-colour lines for the alternates (tap
  /// to select), the selected route's full colour rendering on top. During
  /// navigation only the selected route draws.
  Set<Polyline> _planPolylines(
    PlanResult result,
    int selectedIndex,
    int? activeLeg,
    ColorScheme cs,
  ) {
    final lines = <Polyline>{};
    if (activeLeg == null) {
      for (final (i, route) in result.routes.indexed) {
        if (i == selectedIndex) continue;
        final pts = routePoints(route);
        if (pts.length < 2) continue;
        lines.add(
          Polyline(
            polylineId: PolylineId('alt_$i'),
            points: pts,
            width: 4,
            color: kAltRouteColor,
            consumeTapEvents: true,
            onTap: () => onAlternateTap(i),
          ),
        );
      }
    }
    lines.addAll(
      routePolylines(result.routes[selectedIndex], cs, activeLeg: activeLeg),
    );
    return lines;
  }

  // ── markers ───────────────────────────────────────────────────────────────

  Color _dim(Color c, {required bool dim}) =>
      dim ? c.withValues(alpha: 0.3) : c;

  /// The cached descriptor, or null while it renders. Requesting a missing one
  /// schedules its generation; on completion the memo is dropped and
  /// [onBitmapReady] fires so the marker joins the next frame.
  BitmapDescriptor? _resolveMarker(
    String key,
    Future<BitmapDescriptor> Function() build,
  ) {
    final cached = _markerCache[key];
    if (cached != null) return cached;
    if (_pending.add(key)) {
      unawaited(
        build().then((icon) {
          if (_disposed) return;
          _pending.remove(key);
          _markerCache[key] = icon;
          _memoResult = null;
          onBitmapReady();
        }),
      );
    }
    return null;
  }

  BitmapDescriptor? _originMarker(ColorScheme cs, {required bool dim}) {
    final ring = _dim(cs.onSurface, dim: dim);
    final fill = _dim(Colors.white, dim: dim);
    return _resolveMarker(
      'go_origin|${ring.toARGB32()}|${fill.toARGB32()}',
      () => MapMarkers.dot(fill, ring: ring, size: 20),
    );
  }

  BitmapDescriptor? _destMarker(ColorScheme cs, {required bool dim}) {
    final fill = _dim(cs.onSurface, dim: dim);
    final inner = _dim(Colors.white, dim: dim);
    return _resolveMarker(
      'go_dest|${fill.toARGB32()}|${inner.toARGB32()}',
      () => MapMarkers.targetDot(fill, inner),
    );
  }

  BitmapDescriptor? _boundaryMarker(Color color, {required bool dim}) {
    final ring = _dim(color, dim: dim);
    final fill = _dim(Colors.white, dim: dim);
    return _resolveMarker(
      'go_boundary|${ring.toARGB32()}|${fill.toARGB32()}',
      () => MapMarkers.dot(fill, ring: ring, size: 16),
    );
  }

  BitmapDescriptor? _stopMarker(ColorScheme cs, {required bool dim}) {
    final ring = _dim(cs.outline, dim: dim);
    final fill = _dim(Colors.white, dim: dim);
    return _resolveMarker(
      'go_stop|${ring.toARGB32()}|${fill.toARGB32()}',
      () => MapMarkers.dot(fill, ring: ring, size: 9),
    );
  }

  Set<Marker> _planMarkers(PlanRoute route, int? activeLeg, ColorScheme cs) {
    final sections = route.sections;
    if (sections.isEmpty) return const {};
    final markers = <Marker>{};
    // Higher-priority markers claim a coordinate first; a lower-priority marker
    // at the same spot (a transfer boundary under the origin, say) is skipped.
    final used = <String>{};
    String posKey(PlanPoint p) =>
        '${p.lat.toStringAsFixed(6)},${p.lng.toStringAsFixed(6)}';
    bool valid(PlanPoint p) => p.lat != 0 || p.lng != 0;
    bool dimLeg(int i) => activeLeg != null && i < activeLeg;

    void place(String id, PlanPoint p, BitmapDescriptor? icon, int z) {
      if (icon == null || !valid(p) || !used.add(posKey(p))) return;
      markers.add(
        Marker(
          markerId: MarkerId(id),
          position: LatLng(p.lat, p.lng),
          icon: icon,
          anchor: const Offset(0.5, 0.5),
          zIndexInt: z,
        ),
      );
    }

    place(
      'origin',
      sections.first.departure.location,
      _originMarker(cs, dim: dimLeg(0)),
      30,
    );
    place(
      'dest',
      sections.last.arrival.location,
      _destMarker(cs, dim: dimLeg(sections.length - 1)),
      30,
    );
    for (final (i, s) in sections.indexed) {
      if (isWalk(s)) continue;
      final icon = _boundaryMarker(
        transitColor(s.transport, cs),
        dim: dimLeg(i),
      );
      place('board_$i', s.departure.location, icon, 20);
      place('alight_$i', s.arrival.location, icon, 20);
    }
    for (final (i, s) in sections.indexed) {
      if (isWalk(s)) continue;
      final dim = dimLeg(i);
      for (final (j, stop) in s.intermediateStops.indexed) {
        place('stop_${i}_$j', stop.location, _stopMarker(cs, dim: dim), 10);
      }
    }
    return markers;
  }

  Marker? _navPuck(ColorScheme cs, {required double heading, LatLng? fix}) {
    if (fix == null) return null;
    // Card colour matches the nav header's card (white in light, elevated
    // surface in dark); it forms the puck's ring and arrow glyph.
    final card = cs.brightness == Brightness.light
        ? Colors.white
        : cs.surfaceContainerHigh;
    final icon = _resolveMarker(
      'go_nav_puck|${cs.onSurface.toARGB32()}|${card.toARGB32()}',
      () => MapMarkers.navArrow(cs.onSurface, card),
    );
    if (icon == null) return null;
    return Marker(
      markerId: const MarkerId('nav_puck'),
      position: fix,
      icon: icon,
      anchor: const Offset(0.5, 0.5),
      rotation: heading,
      flat: true,
      zIndexInt: 40,
      // Doubles as the recenter affordance: tapping re-arms follow and snaps
      // back to the user. Harmless while already following (the puck is
      // centred); it only matters after a gesture pause.
      onTap: onPuckTap,
    );
  }
}

/// Every coordinate one route passes through, for framing and for the muted
/// alternate lines.
List<LatLng> routePoints(PlanRoute route) => [
  for (final s in route.sections) ...[
    if (s.departure.location.lat != 0 || s.departure.location.lng != 0)
      LatLng(s.departure.location.lat, s.departure.location.lng),
    if (s.arrival.location.lat != 0 || s.arrival.location.lng != 0)
      LatLng(s.arrival.location.lat, s.arrival.location.lng),
  ],
];

@visibleForTesting
Set<Polyline> routePolylines(
  PlanRoute route,
  ColorScheme cs, {
  int? activeLeg,
}) {
  final lines = <Polyline>{};
  for (final (i, s) in route.sections.indexed) {
    final walk = isWalk(s);
    final pts = <LatLng>[];
    void add(PlanPoint point) {
      if (point.lat != 0 || point.lng != 0) {
        pts.add(LatLng(point.lat, point.lng));
      }
    }

    if (walk && s.walkPath.isNotEmpty) {
      s.walkPath.forEach(add);
    } else if (!walk && s.transitPath.isNotEmpty) {
      s.transitPath.forEach(add);
    } else {
      add(s.departure.location);
      for (final stop in s.intermediateStops) {
        add(stop.location);
      }
      add(s.arrival.location);
    }
    if (pts.length < 2) continue;
    final dim = activeLeg != null && i < activeLeg;
    Color d(Color c) => dim ? c.withValues(alpha: 0.3) : c;
    if (walk) {
      // White-cased ink dots: a wide card-coloured casing under narrower ink
      // dots, both on the same points and pattern so the dots read against any
      // map background. Card colour matches the nav header's card.
      final card = cs.brightness == Brightness.light
          ? Colors.white
          : cs.surfaceContainerHigh;
      final pattern = [PatternItem.dot, PatternItem.gap(16)];
      lines
        ..add(
          Polyline(
            polylineId: PolylineId('leg_${i}_casing'),
            points: pts,
            width: 11,
            color: d(card),
            // Casing sits below its dots, both above the muted alternates.
            zIndex: 2,
            patterns: pattern,
          ),
        )
        ..add(
          Polyline(
            polylineId: PolylineId('leg_$i'),
            points: pts,
            width: 7,
            color: d(cs.onSurface),
            zIndex: 3,
            patterns: pattern,
          ),
        );
    } else {
      lines.add(
        Polyline(
          polylineId: PolylineId('leg_$i'),
          points: pts,
          width: 6,
          color: d(transitColor(s.transport, cs)),
          // Sits above the muted alternates.
          zIndex: 2,
        ),
      );
    }
  }
  return lines;
}
