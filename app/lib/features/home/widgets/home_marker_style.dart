import 'package:flutter/painting.dart' show Color;
import 'package:google_maps_flutter/google_maps_flutter.dart'
    show BitmapDescriptor;
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/core/assets/remote_assets.dart';
import 'package:wheres_the_bus/data/models/near_models.dart';
import 'package:wheres_the_bus/shared/map/marker_factory.dart';
import 'package:wheres_the_bus/shared/widgets/transport_icon.dart';

const kLargeDotZoomThreshold = 13.0;
const kIconZoomThreshold = 15.5;
// largeDot renders at the mid zoom band (bigger, easier to tap); smallDot at
// the most zoomed-out band, where dense clusters need to shrink to stay
// legible.
const kSmallDotSize = 7.0;
const kLargeDotSize = 10.0;
const kIconMarkerSize = 24.0;
const kHighlightIconMarkerSize = 44.0;
const kMapMarkerLimit = 60;

enum MarkerStyle { icon, largeDot, smallDot }

MarkerStyle markerStyleForZoom(double zoom) {
  if (zoom >= kIconZoomThreshold) return MarkerStyle.icon;
  if (zoom >= kLargeDotZoomThreshold) return MarkerStyle.largeDot;
  return MarkerStyle.smallDot;
}

String _mrtLineCode(String stationId) =>
    stationId.split(RegExp(r'[_\d]')).first.toUpperCase();

/// Blue doubles as the fallback, so a code with no case of its own (or one
/// not published yet) still gets a line colour.
Color mrtColor(String stationId) {
  return switch (_mrtLineCode(stationId)) {
    'R' => AppTheme.mrtR,
    'G' => AppTheme.mrtG,
    'O' => AppTheme.mrtO,
    'BR' => AppTheme.mrtBR,
    'Y' => AppTheme.mrtY,
    'C' => AppTheme.mrtKG,
    _ => AppTheme.mrtBL,
  };
}

double dotMarkerSize(MarkerStyle style) =>
    style == MarkerStyle.largeDot ? kLargeDotSize : kSmallDotSize;

Future<BitmapDescriptor> markerIcon(
  NearStationViewModel s,
  MarkerStyle style, {
  bool highlighted = false,
}) {
  if (highlighted) {
    return _iconMarker(s, kHighlightIconMarkerSize);
  }
  if (style == MarkerStyle.icon) {
    return _iconMarker(s, kIconMarkerSize);
  }
  final dotSize = dotMarkerSize(style);
  return switch (s.type) {
    NearStationType.bus => MapMarkers.dot(AppTheme.markerBus, size: dotSize),
    NearStationType.bike => MapMarkers.dot(AppTheme.markerBike, size: dotSize),
    NearStationType.mrt => MapMarkers.dot(
      mrtColor(s.stationId),
      size: dotSize,
    ),
    NearStationType.tra ||
    NearStationType.thsr => MapMarkers.dot(AppTheme.markerRail, size: dotSize),
  };
}

Future<BitmapDescriptor> _iconMarker(
  NearStationViewModel station,
  double size,
) {
  final asset = iconAsset(station);
  if (asset != null) return MapMarkers.svgAsset(asset, size: size);
  // A missing file aborts the whole marker frame, so artwork that is not
  // bundled or not yet mirrored keeps the colored-dot representation.
  final remote = remoteIconPath(station);
  final mirrored = remote == null ? null : RemoteAssets.instance.lookup(remote);
  if (mirrored == null) {
    return MapMarkers.dot(mrtColor(station.stationId), size: size);
  }
  return MapMarkers.svgRemote(mirrored, size: size);
}

String? iconAsset(NearStationViewModel s) {
  return switch (s.type) {
    NearStationType.bus => 'assets/marker/Bus.svg',
    NearStationType.bike => 'assets/marker/bike.svg',
    _ => null,
  };
}

/// Icons the router serves; see [RemoteAssets].
String? remoteIconPath(NearStationViewModel s) {
  return switch (s.type) {
    NearStationType.mrt => _mrtIconAsset(s.stationId),
    NearStationType.tra => 'rails/TRA.svg',
    NearStationType.thsr => 'rails/THSR.svg',
    _ => null,
  };
}

String? _mrtIconAsset(String stationId) {
  final code = _mrtLineCode(stationId);
  const taipeiCodes = {'BL', 'BR', 'G', 'O', 'R', 'Y', 'K'};
  // Unprefixed Taipei codes resolve to their TRTC line icon.
  if (taipeiCodes.contains(code)) return 'mrt/TRTC/$code.svg';
  return null;
}

TransportType nearbyIconType(NearStationViewModel s) {
  return switch (s.type) {
    NearStationType.bus => TransportType.bus,
    NearStationType.bike => TransportType.bike,
    NearStationType.mrt => _mrtLineType(s.stationId),
    NearStationType.tra => TransportType.tra,
    NearStationType.thsr => TransportType.thsr,
  };
}

TransportType _mrtLineType(String stationId) {
  return switch (_mrtLineCode(stationId)) {
    'R' => TransportType.mrtR,
    'G' => TransportType.mrtG,
    'O' => TransportType.mrtO,
    'BR' => TransportType.mrtBR,
    'Y' => TransportType.mrtY,
    'C' => TransportType.mrtKG,
    _ => TransportType.mrtBL,
  };
}
