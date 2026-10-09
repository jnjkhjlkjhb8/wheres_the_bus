part of '../home_screen.dart';

const _kLargeDotZoomThreshold = 13.0;
const _kIconZoomThreshold = 15.5;
// largeDot renders at the mid zoom band (bigger, easier to tap); smallDot at
// the most zoomed-out band, where dense clusters need to shrink to stay
// legible.
const _kSmallDotSize = 7.0;
const _kLargeDotSize = 10.0;
const _kIconMarkerSize = 24.0;
const _kHighlightIconMarkerSize = 44.0;
const _kMapMarkerLimit = 60;

enum _MarkerStyle { icon, largeDot, smallDot }

_MarkerStyle _markerStyle(double zoom) {
  if (zoom >= _kIconZoomThreshold) return _MarkerStyle.icon;
  if (zoom >= _kLargeDotZoomThreshold) return _MarkerStyle.largeDot;
  return _MarkerStyle.smallDot;
}

Color _mrtColor(String stationId) {
  final code = stationId.split(RegExp(r'[_\d]')).first.toUpperCase();
  switch (code) {
    case 'BL':
      return AppTheme.mrtBL;
    case 'R':
      return AppTheme.mrtR;
    case 'G':
      return AppTheme.mrtG;
    case 'O':
      return AppTheme.mrtO;
    case 'BR':
      return AppTheme.mrtBR;
    case 'Y':
      return AppTheme.mrtY;
    default:
      return AppTheme.mrtBL;
  }
}

double _dotMarkerSize(_MarkerStyle style) =>
    style == _MarkerStyle.largeDot ? _kLargeDotSize : _kSmallDotSize;

Future<BitmapDescriptor> _markerIcon(
  NearStationViewModel s,
  _MarkerStyle style, {
  bool highlighted = false,
}) {
  if (highlighted) {
    return MapMarkers.svgAsset(_iconAsset(s), size: _kHighlightIconMarkerSize);
  }
  if (style == _MarkerStyle.icon) {
    return MapMarkers.svgAsset(_iconAsset(s), size: _kIconMarkerSize);
  }
  final dotSize = _dotMarkerSize(style);
  switch (s.type) {
    case NearStationType.bus:
      return MapMarkers.dot(AppTheme.markerBus, size: dotSize);
    case NearStationType.bike:
      return MapMarkers.dot(AppTheme.markerBike, size: dotSize);
    case NearStationType.mrt:
      return MapMarkers.dot(_mrtColor(s.stationId), size: dotSize);
    case NearStationType.tra:
    case NearStationType.thsr:
      return MapMarkers.dot(AppTheme.markerRail, size: dotSize);
  }
}

String _iconAsset(NearStationViewModel s) {
  switch (s.type) {
    case NearStationType.bus:
      return 'assets/marker/Bus.svg';
    case NearStationType.bike:
      return 'assets/marker/bike.svg';
    case NearStationType.mrt:
      return _mrtIconAsset(s.stationId);
    case NearStationType.tra:
      return 'assets/rails/TRA.svg';
    case NearStationType.thsr:
      return 'assets/rails/THSR.svg';
  }
}

String _mrtIconAsset(String stationId) {
  final code = stationId.split(RegExp(r'[_\d]')).first.toUpperCase();
  switch (code) {
    // Taipei metro line codes carry no system prefix, so they default to the
    // TRTC icon until stationId encodes the system.
    case 'BL':
    case 'BR':
    case 'G':
    case 'O':
    case 'R':
    case 'Y':
    case 'K':
      return 'assets/mrt/TRTC/$code.svg';
    case 'C':
      return 'assets/mrt/KLRT/C.svg';
    default:
      return 'assets/mrt/TRTC/R.svg';
  }
}

TransportType _nearbyIconType(NearStationViewModel s) {
  switch (s.type) {
    case NearStationType.bus:
      return TransportType.bus;
    case NearStationType.bike:
      return TransportType.bike;
    case NearStationType.mrt:
      return _mrtLineType(s.stationId);
    case NearStationType.tra:
      return TransportType.tra;
    case NearStationType.thsr:
      return TransportType.thsr;
  }
}

TransportType _mrtLineType(String stationId) {
  final code = stationId.split(RegExp(r'[_\d]')).first.toUpperCase();
  switch (code) {
    case 'BL':
      return TransportType.mrtBL;
    case 'R':
      return TransportType.mrtR;
    case 'G':
      return TransportType.mrtG;
    case 'O':
      return TransportType.mrtO;
    case 'BR':
      return TransportType.mrtBR;
    case 'Y':
      return TransportType.mrtY;
    default:
      return TransportType.mrtBL;
  }
}
