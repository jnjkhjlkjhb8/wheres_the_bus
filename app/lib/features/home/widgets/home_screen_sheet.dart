part of '../home_screen.dart';

extension _HomeScreenSheetX on _HomeScreenState {
  void _syncSheetToLocation() {
    if (!mounted) return;
    _syncStationLocation(widget.station);
    _syncRailQueryLocation();
  }

  void _syncStationLocation(NearStationRouteArgs? args) {
    final key = args == null ? null : '${args.type.name}:${args.id}';
    if (key != _shownStationKey) {
      _shownStationKey = key;
      _shownStationBack = args?.back;
      if (args == null) {
        _popSheetToRoot();
      } else {
        _showStationDetail(_resolveStation(args));
      }
    }
  }

  void _syncRailQueryLocation() {
    if (widget.showRailQuery != _railQueryShown) {
      _railQueryShown = widget.showRailQuery;
      if (widget.showRailQuery) {
        _showRailQuerySheet();
      } else {
        _closeRailQuerySheet();
      }
    }
  }

  void _closeRailQuerySheet() {
    if (_shownStationKey == null) _popSheetToRoot();
  }

  NearStationViewModel _resolveStation(NearStationRouteArgs args) {
    final tapped = _tappedStation;
    _tappedStation = null;
    if (tapped != null && _matchesStation(tapped, args)) {
      return tapped;
    }
    final existing = _stations
        .where((station) => _matchesStation(station, args))
        .firstOrNull;
    if (existing != null) return existing;
    return NearStationViewModel(
      type: args.type,
      stationId: args.id,
      stationName: args.name ?? '',
      // A location with no coordinates cannot move the camera anywhere
      // meaningful, so it leaves it where the rider already is.
      lat: args.lat ?? _center.latitude,
      lon: args.lon ?? _center.longitude,
      walkingMinutes: 0,
      distanceMeters: 0,
    );
  }

  bool _matchesStation(
    NearStationViewModel station,
    NearStationRouteArgs args,
  ) => station.type == args.type && station.stationId == args.id;

  void _popSheetToRoot() {
    final navigator = _sheetNavigatorKey.currentState;
    if (navigator == null || !navigator.canPop()) return;
    navigator.popUntil((route) => route.isFirst);
  }

  void _showStationDetail(NearStationViewModel station) {
    // Only bus stations are groups of poles; everything else is one place and
    // keeps the plain highlight.
    final grouped = station.type == NearStationType.bus;
    if (grouped) {
      _openStopBloc(station);
    } else {
      // Switching to a different kind of station is not a "close" gesture, so
      // the poles leave without the collapse.
      _endSpread();
    }
    _focusStationOnMap(station, spread: grouped);
    _pushStationDetail(station, grouped: grouped);
  }

  void _pushStationDetail(
    NearStationViewModel station, {
    required bool grouped,
  }) {
    final navigator = _sheetNavigatorKey.currentState;
    if (navigator == null) return;
    final token = ++_detailToken;
    unawaited(
      navigator
          // Station detail always sits directly on the root page: tapping a
          // marker from a pushed page replaces that page instead of stacking
          // on it, so one back gesture returns to the nearby list.
          .pushAndRemoveUntil(
            PagedSheetRoute<void>(
              scrollConfiguration: const SheetScrollConfiguration(),
              // Open where the sheet already is, so drilling in from the
              // nearby list doesn't jump the height.
              initialOffset: carriedSheetOffset(
                _sheetController,
                min: AppSheetSnap.peekFrac,
                max: AppSheetSnap.full,
                fallback: AppSheetSnap.halfFrac,
              ),
              snapGrid: AppSheetSnap.grid,
              builder: (_) => stationDetailPage(
                station,
                bloc: grouped ? _stopBloc : null,
              ),
            ),
            (route) => route.isFirst,
          )
          .then((_) => _finishStationDetail(token)),
    );
  }

  void _finishStationDetail(int token) {
    // A newer detail page has already replaced this one; only the page
    // still on screen may clear the map state it set up.
    if (token != _detailToken) return;
    _highlightedKey = null;
    // The collapse gives the group's pin back to the nearby set itself
    // when the poles have landed on it, so the rebuild waits for it
    // rather than racing it.
    _collapseSpread();
    if (!mounted || _shownStationKey == null) return;
    _shownStationKey = null;
    final back = _shownStationBack;
    _shownStationBack = null;
    context.go(back ?? AppRoutes.home);
  }

  void _onStationTap(NearStationViewModel station) {
    _tappedStation = station;
    context.go(
      AppRoutes.nearStation(
        type: station.type,
        id: station.stationId,
        name: station.stationName,
        lat: station.lat,
        lon: station.lon,
      ),
    );
  }

  /// Opens the rail form the same way a station opens — through the location,
  /// so `/rail-query` is a place and not just a gesture.
  void _onRailQueryTap() => context.go(AppRoutes.railQuery());

  void _showRailQuerySheet() {
    final navigator = _sheetNavigatorKey.currentState;
    if (navigator == null) return;
    unawaited(
      navigator
          // On the root page, never on a station detail: the form is a
          // top-level entry point, so one back gesture returns to the nearby
          // list rather than to whatever was open before it.
          .pushAndRemoveUntil(
            PagedSheetRoute<void>(
              scrollConfiguration: const SheetScrollConfiguration(),
              initialOffset: AppSheetSnap.half,
              snapGrid: AppSheetSnap.grid,
              builder: (_) => const HomeRailQuerySheet(),
            ),
            (route) => route.isFirst,
          )
          .then((_) {
            // As in [_showStationDetail]: a back gesture the router never saw
            // would otherwise leave the location on a form that is gone.
            if (!mounted || !_railQueryShown) return;
            _railQueryShown = false;
            context.go(AppRoutes.home);
          }),
    );
  }
}
