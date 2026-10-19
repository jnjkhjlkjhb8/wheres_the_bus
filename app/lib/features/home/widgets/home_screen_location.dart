part of '../home_screen.dart';

extension _HomeScreenLocationX on _HomeScreenState {
  int _initialTabIndex() =>
      FavoritesRepository.instance.pinned().isNotEmpty ? 0 : 1;

  void _onFavoritesReady() {
    if (!App.isInitialized.value || _tabApplied) return;
    _tabApplied = true;
    if (FavoritesRepository.instance.pinned().isNotEmpty) {
      _tabController.animateTo(0);
    }
  }

  Future<void> _initializeMapPosition() async {
    // The map is already on screen at the default centre by now. Jump it to
    // the last OS-cached fix rather than blocking on a fresh GPS fix, which
    // can take up to 10 s cold; the fresh fix pans the camera when it lands.
    final last = await LocationService.instance.lastKnownPosition();
    _seedCachedFix(last);
    if (!mounted) return;
    try {
      final pos = await LocationService.instance.currentPosition();
      unawaited(
        HiveStore.setLastDevicePosition(pos.latitude, pos.longitude),
      );
      if (!mounted) return;
      _applyInitialFix(pos);
    } on Object catch (e, s) {
      _handleLocationFailure(e, s);
    } finally {
      _markLocationResolved();
    }
  }

  void _seedCachedFix(Position? last) {
    if (last == null) return;
    unawaited(HiveStore.setLastDevicePosition(last.latitude, last.longitude));
    if (!mounted) return;
    // This extension implements the owning State lifecycle.
    // ignore: invalid_use_of_protected_member
    setState(() {
      _center = LatLng(last.latitude, last.longitude);
      _camCenter = _center;
      _deviceLocationResolved = true;
    });
    unawaited(_mapController?.moveCamera(CameraUpdate.newLatLng(_center)));
  }

  void _applyInitialFix(Position pos) {
    final target = LatLng(pos.latitude, pos.longitude);
    // This extension implements the owning State lifecycle.
    // ignore: invalid_use_of_protected_member
    setState(() {
      _center = target;
      _camCenter = target;
    });
    // If the map is already up, pan to the fix; the resulting camera-idle
    // re-queries nearby stations. Before map creation, initialCameraPosition
    // picks up the new _center on its own.
    final controller = _mapController;
    if (controller != null) {
      unawaited(controller.animateCamera(CameraUpdate.newLatLng(target)));
    }
  }

  void _markLocationResolved() {
    // This extension implements the owning State lifecycle.
    // ignore: invalid_use_of_protected_member
    if (mounted) setState(() => _deviceLocationResolved = true);
  }

  void _setLocating(bool locating) {
    // This extension implements the owning State lifecycle.
    // ignore: invalid_use_of_protected_member
    if (mounted) setState(() => _locating = locating);
  }

  Future<void> _locateUser() async {
    _setLocating(true);
    try {
      final pos = await LocationService.instance.currentPosition();
      final target = LatLng(pos.latitude, pos.longitude);
      if (!mounted) return;
      // This extension implements the owning State lifecycle.
      // ignore: invalid_use_of_protected_member
      setState(() {
        _center = target;
        _camCenter = target;
        _locating = false;
      });
      final controller = _mapController;
      if (controller == null) return;
      // The ring itself plays off the search the resulting camera-idle
      // decides; this only marks that search as the deliberate kind, which
      // earns the full sweep — see [_playScanSweep].
      _scanFromLocate = true;
      unawaited(controller.animateCamera(CameraUpdate.newLatLng(target)));
    } on Object catch (e, s) {
      _setLocating(false);
      _handleLocationFailure(e, s);
    }
  }

  void _handleLocationFailure(Object e, StackTrace s) {
    final serviceOff = e is LocationServiceDisabledException;
    if (e is PermissionDeniedException || serviceOff) {
      if (mounted) _showLocationDenied(serviceOff);
      return;
    }
    CrashReporter.record(e, s);
  }

  void _showLocationDenied(bool serviceOff) {
    final i18n = AppI18n.of(context);
    AppSnackbar.show(
      context,
      serviceOff ? i18n.alertsLocationOff : i18n.alertsLocationDenied,
      action: serviceOff
          ? i18n.alertsOpenLocationService
          : i18n.alertsOpenLocationPermission,
      onAction: () => unawaited(
        serviceOff
            ? Geolocator.openLocationSettings()
            : Geolocator.openAppSettings(),
      ),
    );
  }

  void _recenter() {
    unawaited(_locateUser());
  }

  Future<void> _requestNearbyForViewport(NearbyBloc bloc) async {
    // Home queries only once the camera is on a real device position — never
    // off the default-Taipei centre the map falls back to meanwhile.
    if (!_deviceLocationResolved) return;
    final radius = await _viewportRadius();
    if (radius == null) return;
    final send = _viewportQuery.shouldQuery(_camCenter, radius);
    _respondToNearbyAttempt(send, radius);
    if (!send) return;
    _viewportQuery = _viewportQuery.withAttempted(_camCenter, radius);
    bloc.add(
      NearbyRequested(
        lat: _camCenter.latitude,
        lon: _camCenter.longitude,
        radius: radius,
      ),
    );
  }

  Future<int?> _viewportRadius() async {
    final controller = _mapController;
    // The radius is needed before the dedup check, not after: zooming out at a
    // fixed centre changes nothing about distance but does widen what the query
    // has to cover.
    final int radius;
    if (controller == null) {
      // Startup only: the platform view is still being created. Estimating the
      // radius here rather than waiting for it takes ~1 s off cold-start
      // time-to-stations. See [estimatedNearbyRadius].
      radius = estimatedNearbyRadius(
        size: MediaQuery.sizeOf(context),
        bottomPadding: _mapBottomPadding(context),
        center: _camCenter,
        zoom: _zoom,
      );
    } else {
      final bounds = await controller.getVisibleRegion();
      if (!mounted) return null;
      radius = nearbyRadiusForViewport(center: _camCenter, bounds: bounds);
    }
    return radius;
  }

  void _respondToNearbyAttempt(bool send, int radius) {
    final fromLocate = _scanFromLocate;
    _scanFromLocate = false;
    // A tap on the locate button is answered even when the dedup skips the
    // query: "this area is already covered" is the honest reply, and a button
    // that does nothing visible is what the ring exists to fix.
    if (send || fromLocate) {
      unawaited(_playScanSweep(radius, still: !fromLocate));
    }
  }

  void _scheduleNearbyForViewport() {
    _idleDebounce?.cancel();
    if (_viewportQuery.inFlight == null &&
        _viewportQuery.lastSuccessful == null) {
      unawaited(_requestNearbyForViewport(_nearbyBloc));
      return;
    }
    _idleDebounce = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      unawaited(_requestNearbyForViewport(_nearbyBloc));
    });
  }

  Future<void> _playScanSweep(int meters, {required bool still}) async {
    if (!mounted) return;
    final quiet = still || AppMotion.reduced(context);
    final size = MediaQuery.sizeOf(context);
    _scanRing.value = (
      // Centre of what was searched: the map centres its camera target in the
      // space left above the sheet's bottom padding, and the query is centred
      // on that same target.
      center: Offset(
        size.width / 2,
        (size.height - _mapBottomPadding(context)) / 2,
      ),
      radiusPx: screenPixelsForMeters(
        meters: meters,
        latitude: _camCenter.latitude,
        zoom: _zoom,
      ),
      still: quiet,
    );
    _scanController.duration = quiet ? AppMotion.scanStill : AppMotion.scan;
    await _scanController.forward(from: 0);
  }
}
