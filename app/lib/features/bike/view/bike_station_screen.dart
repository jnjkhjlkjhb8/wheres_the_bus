import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:smooth_sheets/smooth_sheets.dart';
import 'package:wheres_the_bus/app/theme/app_shadows.dart';
import 'package:wheres_the_bus/core/firebase/crash_reporter.dart';
import 'package:wheres_the_bus/core/location/location_service.dart';
import 'package:wheres_the_bus/data/repositories/bike_repository.dart';
import 'package:wheres_the_bus/features/bike/bloc/bike_station_bloc.dart';
import 'package:wheres_the_bus/features/bike/bloc/bike_station_state.dart';
import 'package:wheres_the_bus/features/bike/view/bike_station_detail_view.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/map/map_color_scheme.dart';
import 'package:wheres_the_bus/shared/map/marker_factory.dart';
import 'package:wheres_the_bus/shared/motion/app_motion.dart';
import 'package:wheres_the_bus/shared/motion/pressable.dart';
import 'package:wheres_the_bus/shared/widgets/app_bars.dart';
import 'package:wheres_the_bus/shared/widgets/app_spinner.dart';
import 'package:wheres_the_bus/shared/widgets/bottom_sheet_shell.dart';

const _kDefaultPos = LatLng(25.0330, 121.5654);

class BikeStationScreen extends StatefulWidget {
  const BikeStationScreen({
    required this.stationUid,
    this.name,
    this.lat,
    this.lon,
    this.repository,
    this.reportError = CrashReporter.record,
    super.key,
  });
  final String stationUid;
  final BikeRepository? repository;
  final void Function(Object error, StackTrace stack) reportError;

  /// Caller-supplied station name and coordinates, when known. They seed the
  /// bloc so the title and camera are right on the first frame, with no
  /// network round-trip; the static fetch refines them when it lands.
  final String? name;
  final double? lat;
  final double? lon;

  @override
  State<BikeStationScreen> createState() => _BikeStationScreenState();
}

class _BikeStationScreenState extends State<BikeStationScreen> {
  GoogleMapController? _controller;
  late final SheetController _sheetController;

  // One bloc for both the map (marker/camera target) and the sheet — it is
  // handed to BikeStationDetailView rather than letting the view create its
  // own, which used to double every static fetch and live stream.
  late final BikeStationBloc _bloc;
  BitmapDescriptor? _bikeIcon;
  bool _locating = false;

  /// The one GPS fix requested for map init, shared between `initState` and
  /// `onMapCreated` (both race to move the camera as soon as it's ready) so
  /// they don't each fire their own `currentPosition()` call.
  Future<Position>? _initialPosition;

  @override
  void initState() {
    super.initState();
    _sheetController = SheetController();
    _bloc = BikeStationBloc(
      stationUid: widget.stationUid,
      repository: widget.repository,
      name: widget.name,
      lat: widget.lat,
      lon: widget.lon,
    );
    unawaited(_loadMarkerIcon());
    // With seeded coordinates the camera already opens on the station, so the
    // GPS fallback — and its permission/fix latency — is not needed at all.
    if (!_hasStation(_bloc.state)) {
      _initialPosition = LocationService.instance.currentPosition();
      unawaited(_moveToInitialLocation());
    }
  }

  Future<void> _loadMarkerIcon() async {
    final icon = await MapMarkers.svgAsset('assets/marker/bike.svg', size: 32);
    if (mounted) setState(() => _bikeIcon = icon);
  }

  @override
  void dispose() {
    _controller?.dispose();
    _sheetController.dispose();
    unawaited(_bloc.close());
    super.dispose();
  }

  /// Falls back to a GPS pan only until the station's own coordinates are
  /// known (see the `BlocBuilder` in [build]); once they land, the camera
  /// target comes from the station, not the user's location.
  Future<void> _moveToInitialLocation() async {
    final initial = _initialPosition;
    if (initial == null) return;
    if (_hasStation(_bloc.state)) return;
    await _panToGps(initial);
  }

  Future<void> _panToGps(Future<Position> fix) async {
    try {
      final position = await fix;
      // Station coordinates can arrive while the initial GPS fix is pending.
      if (!mounted || _hasStation(_bloc.state)) return;
      unawaited(
        _controller?.animateCamera(
          CameraUpdate.newLatLng(LatLng(position.latitude, position.longitude)),
        ),
      );
    } on Object catch (error, stack) {
      widget.reportError(error, stack);
    }
  }

  /// User-triggered recenter: always requests a fresh fix, unlike the shared
  /// one-shot [_initialPosition] used during map init.
  Future<void> _moveToLocation() async {
    _setLocating(true);
    try {
      final pos = await LocationService.instance.currentPosition();
      // A GPS request may finish after the map has been disposed.
      if (!mounted) return;
      unawaited(
        _controller?.animateCamera(
          CameraUpdate.newLatLng(LatLng(pos.latitude, pos.longitude)),
        ),
      );
    } on Object catch (e, s) {
      widget.reportError(e, s);
    } finally {
      _setLocating(false);
    }
  }

  void _setLocating(bool value) {
    if (mounted) setState(() => _locating = value);
  }

  void _recenterMap() {
    unawaited(_moveToLocation());
  }

  bool _hasStation(BikeStationState state) => state.lat != 0 || state.lon != 0;

  bool _stationArrived(BikeStationState previous, BikeStationState next) =>
      !_hasStation(previous) && _hasStation(next);

  bool _stationMoved(BikeStationState previous, BikeStationState next) =>
      previous.lat != next.lat || previous.lon != next.lon;

  void _moveToStation(BikeStationState state) {
    unawaited(
      _controller?.animateCamera(
        CameraUpdate.newLatLng(LatLng(state.lat, state.lon)),
      ),
    );
  }

  Widget _stationMap(BuildContext context, BikeStationState state) {
    final hasStation = _hasStation(state);
    final target = hasStation ? LatLng(state.lat, state.lon) : _kDefaultPos;
    return GoogleMap(
      style: mapStyleOf(context),
      initialCameraPosition: CameraPosition(target: target, zoom: 16),
      markers: _stationMarkers(state, target),
      myLocationEnabled: true,
      myLocationButtonEnabled: false,
      zoomControlsEnabled: false,
      // Keep map gestures from dragging the enclosing sheet.
      gestureRecognizers: const {
        Factory<OneSequenceGestureRecognizer>(EagerGestureRecognizer.new),
      },
      onMapCreated: (controller) {
        _controller = controller;
        if (!hasStation) unawaited(_moveToInitialLocation());
      },
    );
  }

  Set<Marker> _stationMarkers(BikeStationState state, LatLng target) {
    if (!_hasStation(state)) return {};
    return {
      Marker(
        markerId: MarkerId(widget.stationUid),
        position: target,
        icon: _bikeIcon ?? BitmapDescriptor.defaultMarker,
        anchor: const Offset(0.5, 0.5),
        infoWindow: InfoWindow(title: state.name),
      ),
    };
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          Positioned.fill(
            child: BlocConsumer<BikeStationBloc, BikeStationState>(
              bloc: _bloc,
              listenWhen: _stationArrived,
              listener: (_, state) => _moveToStation(state),
              buildWhen: _stationMoved,
              builder: _stationMap,
            ),
          ),
          const FloatingAppBar(),

          ValueListenableBuilder<double?>(
            valueListenable: _sheetController,
            builder: (context, offset, child) {
              final currentOffset = offset ?? 0.0;
              return Positioned(
                right: 16,
                bottom: currentOffset + 16,
                child: child!,
              );
            },
            child: Pressable(
              onTap: _recenterMap,
              semanticLabel: AppI18n.of(context).commonLocateMe,
              child: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: cs.brightness == Brightness.light
                      ? Colors.white
                      : cs.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: AppShadows.floating,
                ),
                child: Center(
                  child: AnimatedSwitcher(
                    duration: AppMotion.short,
                    child: _locating
                        ? const AppSpinner(
                            key: ValueKey('locating'),
                            size: 20,
                          )
                        : Icon(
                            Icons.gps_fixed_rounded,
                            key: const ValueKey('idle'),
                            size: 20,
                            color: cs.onSurface,
                          ),
                  ),
                ),
              ),
            ),
          ),

          AppSheet(
            controller: _sheetController,
            child: BikeStationDetailView(
              stationUid: widget.stationUid,
              bloc: _bloc,
            ),
          ),
        ],
      ),
    );
  }
}
