part of '../home_screen.dart';

extension _HomeScreenMapX on _HomeScreenState {
  Future<void> _rebuildMarkers(List<NearStationViewModel> stations) async {
    final revision = ++_markerRevision;
    final style = markerStyleForZoom(_zoom);
    final withheld = _spreadKey;
    final markers = await Future.wait(
      stations
          .take(kMapMarkerLimit)
          .where((s) => '${s.type.name}:${s.stationId}' != withheld)
          .map((s) async {
            final key = '${s.type.name}:${s.stationId}';
            final highlighted = key == _highlightedKey;
            final icon = await markerIcon(s, style, highlighted: highlighted);
            return Marker(
              markerId: MarkerId(key),
              position: LatLng(s.lat, s.lon),
              icon: icon,
              anchor: const Offset(0.5, 0.5),
              // No InfoWindow: Google's own balloon would open alongside the
              // sheet the tap pushes, giving one action two answers, one of
              // them not ours.
              onTap: () {
                _onStationTap(s);
              },
            );
          }),
    );
    if (!mounted || revision != _markerRevision) return;
    _markerStyleCache = style;
    _markers.value = markers.toSet();
  }

  void _focusStationOnMap(NearStationViewModel station, {bool spread = false}) {
    final key = '${station.type.name}:${station.stationId}';
    _highlightedKey = spread ? null : key;
    final controller = _mapController;
    final target = LatLng(station.lat, station.lon);
    _moveStationCamera(controller, target, spread: spread);
    unawaited(_rebuildMarkers(_stations));
  }

  void _moveStationCamera(
    GoogleMapController? controller,
    LatLng target, {
    required bool spread,
  }) {
    if (controller == null) return;
    final update = _stationCameraUpdate(target, spread: spread);
    if (update == null) return;
    _selfDrivenTarget = target;
    unawaited(controller.animateCamera(update));
  }

  CameraUpdate? _stationCameraUpdate(LatLng target, {required bool spread}) {
    // Pan, don't zoom. A tap is not a request to discard the zoom the user
    // chose; only a camera too far out for the icon band gets raised, and
    // only as far as that floor.
    if (_zoom < kIconZoomThreshold) {
      return CameraUpdate.newLatLngZoom(target, kIconZoomThreshold);
    }
    if (_needsPanTo(target, spread: spread)) {
      return CameraUpdate.newLatLng(target);
    }
    return null;
  }

  bool _needsPanTo(LatLng target, {required bool spread}) =>
      !spread || _isOffCentre(context, target);

  /// Whether every pole already sits inside the visible band, with the same
  /// margin a bounds fit would have left around them.
  bool _membersAlreadyFramed(
    BuildContext context,
    List<BusStationMember> members,
  ) => membersFramed(
    members: members,
    viewport: MediaQuery.sizeOf(context),
    bottomPadding: _mapBottomPadding(context),
    center: _camCenter,
    zoom: _zoom,
  );

  /// Whether [target] sits far enough from the camera centre that a tap on it
  /// should recentre. Measured against the visible band — the part of the map
  /// the sheet is not covering — because that is what the user can see.
  bool _isOffCentre(BuildContext context, LatLng target) => isOffCentre(
    size: MediaQuery.sizeOf(context),
    bottomPadding: _mapBottomPadding(context),
    camCenter: _camCenter,
    zoom: _zoom,
    target: target,
  );

  double _mapBottomPadding(BuildContext context) {
    final metrics = _sheetController.metrics;
    return mapBottomPaddingFor(
      screen: MediaQuery.sizeOf(context),
      sheetOffset: metrics?.offset,
      sheetViewport: metrics?.viewportSize,
    );
  }

  void _onCameraIdle(BuildContext context) {
    final style = markerStyleForZoom(_zoom);
    if (style != _markerStyleCache) {
      unawaited(_rebuildMarkers(_nearbyBloc.state.stations));
    }
    final selfDriven = _selfDrivenTarget;
    _selfDrivenTarget = null;
    // Landed where the app sent it: this idle belongs to a tap on a station,
    // not to the rider looking somewhere new — see [_selfDrivenTarget].
    if (_atDrivenTarget(selfDriven)) {
      return;
    }
    _scheduleNearbyForViewport();
  }

  bool _atDrivenTarget(LatLng? target) =>
      target != null &&
      haversineMeters(_camCenter, target) < _kSelfDrivenSlackMeters;

  /// Frames every pole in the group.
  Future<void> _fitMembers(List<BusStationMember> members) async {
    final controller = _mapController;
    if (controller == null) return;
    final bounds = _memberBoundsToFit(members);
    if (bounds == null) return;
    _selfDrivenTarget = boundsCenter(bounds);
    await controller.animateCamera(
      CameraUpdate.newLatLngBounds(
        bounds,
        _kMemberBoundsPadding,
      ),
    );
  }

  LatLngBounds? _memberBoundsToFit(List<BusStationMember> members) {
    if (!_needsMemberFit(members)) return null;
    final bounds = memberBoundsOf(members);
    // A zero-size bounds box zooms all the way in; the preceding station pan
    // already frames poles sharing the same coordinate.
    return boundsCollapsed(bounds) ? null : bounds;
  }

  bool _needsMemberFit(List<BusStationMember> members) =>
      members.length >= 2 && !_membersAlreadyFramed(context, members);
}

/// Whether every pole's projected position sits inside the visible band, with
/// the same margin a bounds fit would have left around them.
@visibleForTesting
bool membersFramed({
  required List<BusStationMember> members,
  required Size viewport,
  required double bottomPadding,
  required LatLng center,
  required double zoom,
}) {
  final right = viewport.width - _kMemberBoundsPadding;
  final bottom = viewport.height - bottomPadding - _kMemberBoundsPadding;
  for (final m in members) {
    final at = projectToScreen(
      point: LatLng(m.lat, m.lon),
      center: center,
      zoom: zoom,
      viewport: viewport,
      bottomPadding: bottomPadding,
    );
    if (outsideMemberFrame(at, right, bottom)) return false;
  }
  return true;
}

@visibleForTesting
bool outsideMemberFrame(Offset at, double right, double bottom) =>
    at.dx < _kMemberBoundsPadding ||
    at.dx > right ||
    at.dy < _kMemberBoundsPadding ||
    at.dy > bottom;

@visibleForTesting
bool isOffCentre({
  required Size size,
  required double bottomPadding,
  required LatLng camCenter,
  required double zoom,
  required LatLng target,
}) {
  final visible = math.min(size.width, size.height - bottomPadding);
  final metres =
      visible *
      _kRecentreThresholdFrac *
      metersPerPixel(camCenter.latitude, zoom);
  final dLat = (target.latitude - camCenter.latitude) * _kMetresPerDegree;
  final dLon =
      (target.longitude - camCenter.longitude) *
      _kMetresPerDegree *
      math.cos(camCenter.latitude * math.pi / 180);
  return math.sqrt(dLat * dLat + dLon * dLon) > metres;
}

/// Height the map keeps clear under the sheet. Before the sheet has measured
/// itself it is a third of the screen, clamped.
@visibleForTesting
double mapBottomPaddingFor({
  required Size screen,
  double? sheetOffset,
  Size? sheetViewport,
}) {
  if (sheetOffset == null || sheetViewport == null) {
    return (screen.height * 0.30).clamp(180.0, 280.0);
  }
  // Parks the logo just above the sheet edge rather than level with the
  // recenter button, so it reads as map chrome instead of a control.
  return math.min(sheetOffset, sheetViewport.height * AppSheetSnap.halfFrac) +
      _kMapLogoGap;
}

@visibleForTesting
LatLngBounds memberBoundsOf(List<BusStationMember> members) {
  double lowest(double Function(BusStationMember) of) =>
      members.map(of).reduce(math.min);
  double highest(double Function(BusStationMember) of) =>
      members.map(of).reduce(math.max);
  return LatLngBounds(
    southwest: LatLng(lowest((m) => m.lat), lowest((m) => m.lon)),
    northeast: LatLng(highest((m) => m.lat), highest((m) => m.lon)),
  );
}

@visibleForTesting
bool boundsCollapsed(LatLngBounds bounds) =>
    bounds.northeast.latitude - bounds.southwest.latitude < 1e-6 &&
    bounds.northeast.longitude - bounds.southwest.longitude < 1e-6;

@visibleForTesting
LatLng boundsCenter(LatLngBounds bounds) => LatLng(
  (bounds.southwest.latitude + bounds.northeast.latitude) / 2,
  (bounds.southwest.longitude + bounds.northeast.longitude) / 2,
);
