import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/data/models/bus_models.dart';
import 'package:wheres_the_bus/data/models/eta_format.dart';
import 'package:wheres_the_bus/data/models/timeline_stop.dart';
import 'package:wheres_the_bus/features/bus/bloc/bus_route_state.dart';
import 'package:wheres_the_bus/features/bus/bus_vehicle_status.dart';
import 'package:wheres_the_bus/features/bus/widgets/bus_timeline_stops.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/map/bus_heading.dart';
import 'package:wheres_the_bus/shared/map/marker_factory.dart';
import 'package:wheres_the_bus/shared/map/wkt.dart';

class BusRouteOverlay {
  BusRouteOverlay({required this.onStopTap, required this.onVehicleTap});

  /// Tapping a stop plate; the screen scrolls its timeline to that stop.
  final void Function(String stopUid) onStopTap;

  /// Tapping a bus mark; the screen pins or unpins that plate.
  final void Function(String plate) onVehicleTap;

  final _markerCache = <String, ({String key, Marker marker})>{};
  final _glides = <String, BusGlide>{};

  String _frameSig = '';
  String? _geometrySig;
  List<List<LatLng>> _geometryLines = const [];
  Set<Marker> _stopMarkers = const {};
  Set<Polyline> _polylines = const {};
  List<LatLng> _stopPoints = const [];

  /// Bumped by every [resolve]; a call whose value no longer matches by the
  /// time it reaches the commit point was overtaken while awaiting bitmaps.
  int _generation = 0;

  /// The stop coordinates of the frame on screen, for the camera fit.
  List<LatLng> get stopPoints => _stopPoints;

  /// Where [plate] was last reported, so the screen can aim the camera at a
  /// bus picked from the sheet. The glide's destination, not its interpolated
  /// position: the camera should land where the bus is going to be sitting.
  LatLng? vehiclePosition(String plate) => _glides[plate]?.to;

  /// The in-flight glides, exposed so a test can assert continuity across
  /// frames; [paint] is the only production reader.
  @visibleForTesting
  Map<String, BusGlide> get glides => Map.unmodifiable(_glides);

  /// Installs glides directly so [paint] can be exercised without rasterising a
  /// frame first. [resolve] is the only production writer.
  @visibleForTesting
  void debugSeedGlides(Map<String, BusGlide> glides) {
    _glides
      ..clear()
      ..addAll(glides);
  }

  void invalidate() {
    _markerCache.clear();
    _frameSig = '';
  }

  Future<BusOverlayFrame?> resolve({
    required BusRouteState state,
    required AppI18n i18n,
    required ColorScheme colors,
    required double glideProgress,
    required DateTime now,
    String? selectedStopUid,
    String? pinnedPlate,
    String? trackedPlate,
    bool pickingStop = false,
  }) async {
    final route = state.route;
    if (route == null) return null;
    final stops = state.direction == 0 ? route.stopsGo : route.stopsReturn;
    if (stops.isEmpty) return null;

    final generation = ++_generation;
    final vehicles = vehiclePositionsFor(state);

    // The one rule for who gets a bubble, shared with the signature below so
    // the two cannot drift: a signature that omitted a shown bubble's clock
    // would freeze its freshness label at whatever it read when it appeared.
    bool showsBubble(BusVehiclePosition v) =>
        pinnedPlate == v.plate ||
        busVehicleStatus(i18n, v).tone == BusStatusTone.warning;

    final sig = frameSignature(
      state: state,
      stops: stops,
      vehicles: vehicles,
      i18n: i18n,
      showsBubble: showsBubble,
      glyphSalt: '$pinnedPlate|$trackedPlate|$pickingStop|$selectedStopUid',
    );
    if (sig == _frameSig) return null;
    _frameSig = sig;

    final stopPoints = [
      for (final st in stops)
        if (st.lat != 0 || st.lon != 0) LatLng(st.lat, st.lon),
    ];

    // Geometry only changes with the route or the direction, and parsing WKT is
    // the one genuinely expensive non-bitmap step here, so it is cached apart
    // from the frame signature that live ETAs churn every 30 s.
    final geometrySig = '${route.subRouteUid}:${state.direction}';
    if (geometrySig != _geometrySig) {
      _geometrySig = geometrySig;
      final geometry = state.direction == 0
          ? route.geometryGo
          : route.geometryReturn;
      var lines = parseWktLines(geometry);
      if (lines.isEmpty && stopPoints.length >= 2) lines = [stopPoints];
      _geometryLines = lines;
    }

    final isDark = colors.brightness == Brightness.dark;
    final isLight = !isDark;

    final polylines = <Polyline>{
      for (var i = 0; i < _geometryLines.length; i++)
        Polyline(
          polylineId: PolylineId('route_$i'),
          points: _geometryLines[i],
          color: colors.onSurface,
          width: 4,
          startCap: Cap.roundCap,
          endCap: Cap.roundCap,
          jointType: JointType.round,
        ),
    };

    final bounds = stopPoints.isEmpty ? null : boundsOf(stopPoints);
    // Same retirement the sheet's timeline applies: read literally the feed
    // republishes 進站中 on every stop the bus has already driven past, and the
    // map would paint a trail of green plates behind it.
    final resolvedEtas = retireStaleArriving([
      for (final st in stops) etaFor(state, st),
    ]);
    final etaByUid = {
      for (final (i, st) in stops.indexed) st.stopUid: resolvedEtas[i],
    };
    final stopMarkers = await _buildStopMarkers(
      stops: stops,
      etaFor: (st) => etaByUid[st.stopUid],
      cs: colors,
      i18n: i18n,
      selectedUid: selectedStopUid,
      // A selected stop's name leans away from the route's mid-longitude, so it
      // falls outside the line rather than over the next stop along.
      midLon: bounds == null
          ? 0
          : (bounds.southwest.longitude + bounds.northeast.longitude) / 2,
      cache: _markerCache,
      onTap: onStopTap,
    );

    // A newer frame may have started and finished while this one awaited the
    // bitmap lookups above; yield rather than spend more time rasterising
    // vehicles for a frame that is about to be discarded.
    if (generation != _generation) return null;

    final nextGlides = await _resolveGlides(
      vehicles: vehicles,
      i18n: i18n,
      colors: colors,
      isLight: isLight,
      glideProgress: glideProgress,
      now: now,
      pinnedPlate: pinnedPlate,
      trackedPlate: trackedPlate,
      pickingStop: pickingStop,
      showsBubble: showsBubble,
    );

    // Same check, now guarding the commit itself: this is the write, so a stale
    // call must not reach it even if everything above finished.
    if (generation != _generation) return null;

    _stopMarkers = stopMarkers;
    _polylines = polylines;
    _stopPoints = stopPoints;
    _glides
      ..clear()
      ..addAll(nextGlides);

    return BusOverlayFrame(
      stopMarkers: stopMarkers,
      polylines: polylines,
      stopPoints: stopPoints,
      hasVehicles: nextGlides.isNotEmpty,
      showsAnyBubble: nextGlides.values.any((g) => g.rebuildBubble != null),
    );
  }

  BusMapLayer paint({required double glideProgress, String? pinnedPlate}) {
    final vehicleMarkers = <Marker>{};
    _glides.forEach((plate, g) {
      final pos = lerpLatLng(g.from, g.to, glideProgress);
      // Once a bus is pinned, the others recede so the pinned one leads.
      final dimmed = pinnedPlate != null && plate != pinnedPlate;
      final alpha = dimmed ? 0.35 : 1.0;
      vehicleMarkers.add(
        Marker(
          markerId: MarkerId('bus:$plate'),
          position: pos,
          icon: g.icon,
          anchor: const Offset(0.5, 0.5),
          alpha: alpha,
          // The mark is painted north-up; rotation points it along the heading,
          // and `flat` makes that a bearing on the ground rather than a spin on
          // the screen.
          rotation: g.headingAt(glideProgress) ?? 0,
          flat: true,
          // Above every stop plate, selected capsule included: the live bus is
          // the one thing on this map that outranks the rider's own tap.
          zIndexInt: 4,
          onTap: () => onVehicleTap(plate),
        ),
      );
      final bubbleIcon = g.bubbleIcon;
      if (bubbleIcon != null) {
        vehicleMarkers.add(
          Marker(
            markerId: MarkerId('bubble:$plate'),
            position: pos,
            icon: bubbleIcon,
            alpha: alpha,
            zIndexInt: 5,
          ),
        );
      }
    });
    return (
      markers: {..._stopMarkers, ...vehicleMarkers},
      polylines: _polylines,
    );
  }

  Future<bool> tickBubbles(DateTime now) async {
    var changed = false;
    for (final glide in _glides.values.toList()) {
      final rebuild = glide.rebuildBubble;
      if (rebuild == null) continue;
      final icon = await rebuild(now);
      if (identical(icon, glide.bubbleIcon)) continue;
      glide.bubbleIcon = icon;
      changed = true;
    }
    return changed;
  }

  Future<Map<String, BusGlide>> _resolveGlides({
    required List<BusVehiclePosition> vehicles,
    required AppI18n i18n,
    required ColorScheme colors,
    required bool isLight,
    required double glideProgress,
    required DateTime now,
    required String? pinnedPlate,
    required String? trackedPlate,
    required bool pickingStop,
    required bool Function(BusVehiclePosition) showsBubble,
  }) async {
    final next = <String, BusGlide>{};
    for (final v in vehicles) {
      final status = busVehicleStatus(i18n, v);
      final statusColor = switch (status.tone) {
        BusStatusTone.normal => colors.onSurface,
        BusStatusTone.notice =>
          isLight ? AppTheme.etaApproaching : AppTheme.statusApproach,
        BusStatusTone.warning => colors.error,
        BusStatusTone.muted => colors.onSurfaceVariant,
      };

      final target = LatLng(v.lat, v.lon);
      final prev = _glides[v.plate];
      // A newly-seen bus starts at its target (no fly-in from nowhere);
      // otherwise it glides from wherever it sits right now.
      final from = prev == null
          ? target
          : lerpLatLng(prev.from, prev.to, glideProgress);

      final heading = headingFor(
        azimuth: v.azimuth,
        previousTo: prev?.to,
        target: target,
        previousHeading: prev?.toHeading,
      );

      // Escalate by fill before colour, the same ladder the stop markers use: a
      // warning takes the whole body, a notice or a muted state only a ring,
      // and a bus with nothing to report stays ink.
      final (Color markBody, Color? markRing) = switch (status.tone) {
        BusStatusTone.normal => (colors.onSurface, null),
        BusStatusTone.warning => (statusColor, null),
        BusStatusTone.notice || BusStatusTone.muted => (
          colors.onSurface,
          statusColor,
        ),
      };
      final icon = await MapMarkers.busMark(
        body: markBody,
        halo: isLight ? AppTheme.surfaceCardLight : AppTheme.surfaceDark,
        ring: markRing,
        showHeading: heading != null,
        // The dark basemap gives a drop shadow nothing to land on; there the
        // near-black halo is what separates the mark (see DESIGN.md).
        shadow: isLight,
      );

      // Takes [at] rather than closing over `now`, so tickBubbles can call it
      // again on a later clock with nothing else about the bubble moving.
      Future<BitmapDescriptor> buildBubble(DateTime at) => MapMarkers.busBubble(
        plate: v.plate,
        fill: isLight ? Colors.white : colors.surfaceContainerHigh,
        inkSecondary: colors.onSurfaceVariant,
        statusLabel: status.label,
        statusColor: statusColor,
        gpsText: busGpsAge(i18n, v.gpsTimeUnix, at).text,
        trackGlyph: switch (v.plate) {
          _ when pickingStop && pinnedPlate == v.plate => '＋',
          _ when trackedPlate == v.plate => '✓',
          _ => null,
        },
      );

      final rebuildBubble = showsBubble(v) ? buildBubble : null;

      next[v.plate] = BusGlide(
        from: from,
        to: target,
        icon: icon,
        // Where the mark points right now, so the turn continues from there.
        fromHeading: prev?.headingAt(glideProgress),
        toHeading: heading,
        bubbleIcon: await rebuildBubble?.call(now),
        rebuildBubble: rebuildBubble,
      );
    }
    return next;
  }
}

/// What one resolved frame committed. The markers and polylines are what the
/// map shows; the rest is what the screen needs to decide follow-up work
/// (fit the camera, run or stop the bubble ticker).
class BusOverlayFrame {
  const BusOverlayFrame({
    required this.stopMarkers,
    required this.polylines,
    required this.stopPoints,
    required this.hasVehicles,
    required this.showsAnyBubble,
  });

  final Set<Marker> stopMarkers;
  final Set<Polyline> polylines;
  final List<LatLng> stopPoints;
  final bool hasVehicles;

  /// Whether any vehicle is showing a bubble, and therefore whether the
  /// once-a-second freshness clock has anything to update.
  final bool showsAnyBubble;
}

/// One layer handed to the `GoogleMap`.
typedef BusMapLayer = ({Set<Marker> markers, Set<Polyline> polylines});

class BusGlide {
  BusGlide({
    required this.from,
    required this.to,
    required this.icon,
    this.fromHeading,
    this.toHeading,
    this.bubbleIcon,
    this.rebuildBubble,
  });

  final LatLng from;
  final LatLng to;
  final BitmapDescriptor icon;

  /// Heading to glide away from, null on a vehicle's first frame — there is no
  /// previous direction to turn out of, so it starts pointed at [toHeading].
  final double? fromHeading;

  /// Heading to glide to, null when the vehicle has no usable one at all. The
  /// mark is then painted without its chevron and the rotation means nothing.
  final double? toHeading;

  BitmapDescriptor? bubbleIcon;

  final Future<BitmapDescriptor> Function(DateTime now)? rebuildBubble;

  /// Heading to paint at glide progress [t]. Read live for the same reason
  /// [from] is: a frame landing mid-turn has to retarget from where the mark is
  /// actually pointing, not snap back to where that turn began.
  double? headingAt(double t) => toHeading == null
      ? null
      : lerpHeading(fromHeading ?? toHeading!, toHeading!, t);
}

LatLng lerpLatLng(LatLng a, LatLng b, double t) => LatLng(
  a.latitude + (b.latitude - a.latitude) * t,
  a.longitude + (b.longitude - a.longitude) * t,
);

double? headingFor({
  required int azimuth,
  required LatLng? previousTo,
  required LatLng target,
  required double? previousHeading,
}) {
  if (azimuth != 0) return azimuth.toDouble();
  if (previousTo == null) return previousHeading;
  return bearingIfMoved(previousTo, target) ?? previousHeading;
}

/// The ETA reading for one stop, tolerating both key shapes the feed uses.
BusStopEtaViewModel? etaFor(BusRouteState state, BusStopModel stop) =>
    state.etaMap['seq:${state.direction}:${stop.sequence}'] ??
    state.etaMap['uid:${stop.stopUid}'];

/// The live vehicles on the state's current direction, one entry per plate.
List<BusVehiclePosition> vehiclePositionsFor(BusRouteState state) {
  final byPlate = <String, BusVehiclePosition>{};
  for (final eta in state.etaMap.values) {
    if (eta.direction != state.direction) continue;
    for (final v in eta.vehicles) {
      byPlate[v.plate] = v;
    }
  }
  return byPlate.values.toList();
}

LatLngBounds boundsOf(List<LatLng> pts) {
  var minLat = pts.first.latitude;
  var maxLat = pts.first.latitude;
  var minLng = pts.first.longitude;
  var maxLng = pts.first.longitude;
  for (final p in pts) {
    minLat = p.latitude < minLat ? p.latitude : minLat;
    maxLat = p.latitude > maxLat ? p.latitude : maxLat;
    minLng = p.longitude < minLng ? p.longitude : minLng;
    maxLng = p.longitude > maxLng ? p.longitude : maxLng;
  }
  return LatLngBounds(
    southwest: LatLng(minLat, minLng),
    northeast: LatLng(maxLat, maxLng),
  );
}

@visibleForTesting
String frameSignature({
  required BusRouteState state,
  required List<BusStopModel> stops,
  required List<BusVehiclePosition> vehicles,
  required AppI18n i18n,
  required bool Function(BusVehiclePosition) showsBubble,
  String glyphSalt = '',
}) {
  final route = state.route;
  return '${route?.subRouteUid}:${state.direction}:${stops.length}:$glyphSalt:'
      '${stops.map((st) => markerEta(i18n, etaFor(state, st))).join(',')}:'
      '${vehicles.map((v) => '${v.plate}@${v.lat},${v.lon},${v.azimuth},'
          '${v.dutyStatus},${v.busStatus}'
          '${showsBubble(v) ? ',${v.gpsTimeUnix}' : ''}').join(';')}';
}

/// What a stop marker's plate says. 進站中 is spelled out rather than abbreviated
/// to 即: the plate turns into a pill for this one state precisely so the word
/// fits, and an abbreviation nobody has to decode is worth the extra width.
String markerEta(AppI18n i18n, BusStopEtaViewModel? eta) {
  if (eta == null) return '–';
  final status = busStopDisplayStatus(
    estimateSeconds: eta.estimateSeconds,
    stopStatus: eta.stopStatus,
  );
  if (status == BusStopDisplayStatus.arriving) return i18n.etaArriving;
  if (eta.estimateSeconds > 0) return '${eta.estimateMinutes}';
  return '–';
}

/// A not-yet-departed stop whose arrival is a scheduled clock time — the map
/// marker shows a clock icon instead of a countdown number.
bool _markerIsScheduled(BusStopEtaViewModel? eta) =>
    eta != null && eta.stopStatus == 1 && eta.nextBusTime.isNotEmpty;

/// A stop whose service is over for the day (末班已過 / 今日未營運) — the map
/// marker shows a cross instead of a countdown, since nothing more is coming.
bool _markerIsEnded(BusStopEtaViewModel? eta) {
  if (eta == null) return false;
  final status = busStopDisplayStatus(
    estimateSeconds: eta.estimateSeconds,
    stopStatus: eta.stopStatus,
  );
  return status == BusStopDisplayStatus.lastBusPassed ||
      status == BusStopDisplayStatus.notOperating;
}

/// A stop with no reading at all — no live estimate and no scheduled time (a
/// missing ETA frame, or 交管 with nothing behind it). Tested against the raw
/// status rather than the rendered '–' so it keeps working in every locale.
bool _markerIsUnknown(BusStopEtaViewModel? eta) =>
    eta == null ||
    (eta.estimateSeconds <= 0 &&
        busStopDisplayStatus(
              estimateSeconds: eta.estimateSeconds,
              stopStatus: eta.stopStatus,
            ) !=
            BusStopDisplayStatus.arriving);

typedef MarkerStyle = ({
  Color fill,
  Color content,
  Color? ring,
  double ringWidth,
  double height,
  String? text,
  IconData? glyph,
  bool pill,
  int zIndex,
});

@visibleForTesting
MarkerStyle markerStyle(
  AppI18n i18n,
  BusStopEtaViewModel? eta,
  ColorScheme cs,
) {
  final isDark = cs.brightness == Brightness.dark;
  // Dark mode's plate can't stay white against the dark basemap, so it borrows
  // the elevated-surface pairing the app's other floating map chrome uses.
  final plate = isDark ? cs.surfaceContainerHigh : AppTheme.surfaceCardLight;
  MarkerStyle quiet({String? text, IconData? glyph}) => (
    fill: plate,
    content: cs.onSurfaceVariant,
    ring: cs.onSurfaceVariant,
    ringWidth: 1.5,
    height: 30,
    text: text,
    glyph: glyph,
    pill: false,
    zIndex: 0,
  );

  if (_markerIsEnded(eta)) return quiet(glyph: Icons.close_rounded);
  if (_markerIsScheduled(eta)) return quiet(glyph: Icons.schedule_rounded);
  if (_markerIsUnknown(eta)) return quiet(text: markerEta(i18n, eta));

  final approach = isDark ? AppTheme.statusApproach : AppTheme.etaApproaching;
  return switch (timelineStopState(eta)) {
    TimelineStopState.arriving => (
      // Green, not red: an arriving bus is the moment to act, not an alarm
      // (DESIGN.md). The light shade is the darker text-weight green,
      // because white sits on this fill and the badge green fails there.
      fill: isDark ? AppTheme.statusArriving : AppTheme.statusArrivingText,
      content: isDark ? AppTheme.inkLight : AppTheme.surfaceCardLight,
      ring: null,
      ringWidth: 0,
      height: 32,
      text: markerEta(i18n, eta),
      glyph: null,
      pill: true,
      zIndex: 2,
    ),
    TimelineStopState.approaching => (
      // The wash is what makes this readable without reading: colour alone is a
      // hue change, colour plus a lighter body is a change in weight.
      fill: Color.alphaBlend(
        approach.withValues(alpha: isDark ? 0.14 : 0.10),
        plate,
      ),
      content: cs.onSurface,
      ring: approach,
      ringWidth: 3,
      height: 34,
      text: markerEta(i18n, eta),
      glyph: null,
      pill: false,
      zIndex: 1,
    ),
    TimelineStopState.none => (
      fill: plate,
      content: cs.onSurface,
      // Thinner than the 3.6 it replaces: the number is the content, the ring
      // only has to lift it off the tiles.
      ring: cs.onSurface,
      ringWidth: 2,
      height: 32,
      text: markerEta(i18n, eta),
      glyph: null,
      pill: false,
      zIndex: 0,
    ),
  };
}

/// Builds the stop layer. Reuses any marker whose rendered inputs are unchanged
/// via [cache], so a live frame costs O(changed) bitmap lookups rather than one
/// per stop on a route that can run 60 stops long.
Future<Set<Marker>> _buildStopMarkers({
  required List<BusStopModel> stops,
  required BusStopEtaViewModel? Function(BusStopModel) etaFor,
  required ColorScheme cs,
  required AppI18n i18n,
  required String? selectedUid,
  required double midLon,
  required Map<String, ({String key, Marker marker})> cache,
  required void Function(String stopUid) onTap,
}) async {
  final markers = <Marker>{};
  final misses = <Future<Marker> Function()>[];
  for (final st in stops) {
    if (st.lat == 0 && st.lon == 0) continue;
    final style = markerStyle(i18n, etaFor(st), cs);
    final selected = st.stopUid == selectedUid;
    final key =
        '${cs.brightness}:${style.text}:${style.glyph?.codePoint}:'
        '${style.height}:${style.pill}:$selected:${st.lat},${st.lon}';
    final cached = cache[st.stopUid];
    if (cached != null && cached.key == key) {
      markers.add(cached.marker);
      continue;
    }
    misses.add(
      () => _rasteriseStopMarker(
        stop: st,
        style: style,
        selected: selected,
        key: key,
        midLon: midLon,
        cs: cs,
        cache: cache,
        onTap: onTap,
      ),
    );
  }
  markers.addAll(await Future.wait([for (final start in misses) start()]));
  return markers;
}

Future<Marker> _rasteriseStopMarker({
  required BusStopModel stop,
  required MarkerStyle style,
  required bool selected,
  required String key,
  required double midLon,
  required ColorScheme cs,
  required Map<String, ({String key, Marker marker})> cache,
  required void Function(String stopUid) onTap,
}) async {
  final plate = await MapMarkers.stopMarker(
    fill: style.fill,
    content: style.content,
    ring: style.ring,
    ringWidth: style.ringWidth,
    height: style.height,
    text: style.text,
    glyph: style.glyph,
    pill: style.pill,
    label: selected ? stop.stopName : null,
    labelFill: cs.onSurface,
    labelInk: cs.surface,
    // The name leans away from the route's middle, so it falls outside the
    // line rather than over it and the next stop along.
    flip: stop.lon < midLon,
  );
  final stopUid = stop.stopUid;
  final marker = Marker(
    markerId: MarkerId(stopUid),
    position: LatLng(stop.lat, stop.lon),
    icon: plate.icon,
    anchor: plate.anchor,
    // A selected capsule is wider than its plate and has to sit over its
    // neighbours; otherwise the ladder decides who wins an overlap.
    zIndexInt: selected ? 3 : style.zIndex,
    onTap: () => onTap(stopUid),
  );
  cache[stopUid] = (key: key, marker: marker);
  return marker;
}
