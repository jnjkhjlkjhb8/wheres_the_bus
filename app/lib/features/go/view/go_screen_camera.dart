part of 'go_screen.dart';

extension _GoScreenCamera on _GoScreenState {
  // Wraps every app-initiated camera animation so onCameraMoveStarted can tell
  // programmatic moves from user gestures (only the latter pause follow mode).
  Future<void> _animateCameraGuarded(CameraUpdate update) async {
    final map = _map;
    if (map == null) return;
    _programmaticMoves++;
    try {
      await map.moveOrAnimate(update, reduced: AppMotion.reduced(context));
    } finally {
      _programmaticMoves--;
      _lastProgrammaticMove = DateTime.now();
    }
  }

  // Subscribes to the compass only while navigating; a no-op if already live so
  // a nav restart doesn't stack subscriptions.
  void _startCompass() {
    _compassSub ??= LocationService.instance.compassStream().listen(
      _onCompassHeading,
    );
  }

  void _stopCompass() {
    unawaited(_compassSub?.cancel());
    _compassSub = null;
    _lastAppliedHeading = null;
  }

  LatLng? _latLngOrNull(PlanPoint? point) {
    if (point == null) return null;
    return LatLng(point.lat, point.lng);
  }

  void _fitTo(PlanRoute route) => _fitBounds(routePoints(route));

  void _fitAll(PlanResult result) {
    final points = [
      for (final route in result.routes) ...routePoints(route),
    ];
    _fitBounds(points);
  }

  void _fitBounds(List<LatLng> points) {
    if (points.length < 2) return;
    final latitudes = points.map((p) => p.latitude);
    final longitudes = points.map((p) => p.longitude);
    final minLat = latitudes.reduce(math.min);
    final maxLat = latitudes.reduce(math.max);
    final minLng = longitudes.reduce(math.min);
    final maxLng = longitudes.reduce(math.max);
    unawaited(
      _animateCameraGuarded(
        CameraUpdate.newLatLngBounds(
          LatLngBounds(
            southwest: LatLng(minLat, minLng),
            northeast: LatLng(maxLat, maxLng),
          ),
          72,
        ),
      ),
    );
  }

  // Frames the pair while the query runs, so the map is about this trip from
  // the first frame instead of sitting on a default city view.
  void _fitPending() {
    final from = _origin?.latLng;
    final to = _dest?.latLng;
    if (from == null || to == null) return;
    _fitBounds([from, to]);
  }
}
