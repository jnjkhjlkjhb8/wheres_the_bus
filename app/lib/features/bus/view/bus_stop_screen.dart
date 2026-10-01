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
import 'package:wheres_the_bus/core/location/nearest_within.dart';
import 'package:wheres_the_bus/data/models/bus_models.dart';
import 'package:wheres_the_bus/features/alerts/view/inline_notice.dart';
import 'package:wheres_the_bus/features/bus/bloc/bus_stop_bloc.dart';
import 'package:wheres_the_bus/features/bus/bloc/bus_stop_event.dart';
import 'package:wheres_the_bus/features/bus/bloc/bus_stop_state.dart';
import 'package:wheres_the_bus/features/bus/view/bus_stop_detail_view.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/map/map_color_scheme.dart';
import 'package:wheres_the_bus/shared/map/marker_factory.dart';
import 'package:wheres_the_bus/shared/motion/app_motion.dart';
import 'package:wheres_the_bus/shared/motion/pressable.dart';
import 'package:wheres_the_bus/shared/widgets/app_bars.dart';
import 'package:wheres_the_bus/shared/widgets/app_spinner.dart';
import 'package:wheres_the_bus/shared/widgets/bottom_sheet_shell.dart';

const _kDefaultPos = LatLng(25.0330, 121.5654);

/// Standing-at-the-pole distance: the two poles of one stop are typically
/// 20–40 m apart across a road, so anything wider stops meaning "this side".
const _kMemberRadiusMeters = 10.0;

/// Deliberately looser than [_kMemberRadiusMeters] — see
/// [_BusStopScreenState._autoSelectMemberAtRider].
const _kMemberAccuracyMeters = 30.0;

class BusStopScreen extends StatefulWidget {
  const BusStopScreen({
    required this.stopName,
    this.stopId,
    this.city,
    this.lat,
    this.lon,
    super.key,
  });
  final String stopName;
  final String? stopId;
  final String? city;

  final double? lat;
  final double? lon;

  @override
  State<BusStopScreen> createState() => _BusStopScreenState();
}

class _BusStopScreenState extends State<BusStopScreen> {
  GoogleMapController? _controller;
  late final SheetController _sheetController;
  BusStopBloc? _blocOrNull;

  /// Non-null from the first `didChangeDependencies` on, which runs before
  /// any build or lifecycle callback that reaches for it.
  BusStopBloc get _bloc => _blocOrNull!;
  BitmapDescriptor? _busIcon;
  bool _locating = false;

  /// The one GPS fix requested for map init, shared between `initState` and
  /// `onMapCreated` (both race to move the camera as soon as it's ready) so
  /// they don't each fire their own `currentPosition()` call.
  Future<Position>? _initialPosition;

  /// The stop's coordinates as supplied by the caller, if any.
  LatLng? get _hint => widget.lat != null && widget.lon != null
      ? LatLng(widget.lat!, widget.lon!)
      : null;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Built here, not in initState: resolving the locale reads an inherited
    // widget, which initState is too early for.
    _blocOrNull ??= BusStopBloc(
      i18n: AppI18n.of(context),
      stopId: widget.stopId,
      city: widget.city,
    );
  }

  @override
  void initState() {
    super.initState();
    _sheetController = SheetController();
    unawaited(_loadMarkerIcon());
    // With a hint the camera already opens on the stop, so the GPS fallback —
    // and its permission/fix latency — is not needed at all.
    if (_hint == null) {
      _initialPosition = LocationService.instance.currentPosition();
      unawaited(_moveToInitialLocation());
    }
  }

  Future<void> _loadMarkerIcon() async {
    final icon = await MapMarkers.svgAsset('assets/marker/Bus.svg', size: 32);
    if (mounted) setState(() => _busIcon = icon);
  }

  /// Animates the map to [pos], the coordinates of the selected member stop.
  void _focusStation(LatLng pos) {
    final controller = _controller;
    if (controller == null) return;
    unawaited(controller.animateCamera(CameraUpdate.newLatLng(pos)));
  }

  @override
  void dispose() {
    _controller?.dispose();
    _sheetController.dispose();
    unawaited(_bloc.close());
    super.dispose();
  }

  /// Falls back to a GPS pan only until the stop's own coordinates are known
  /// (hint or member stops); once they land, the camera target comes from the
  /// stop, not the user's location.
  Future<void> _moveToInitialLocation() async {
    final initial = _initialPosition;
    if (initial == null) return;
    if (_bloc.state.members.isNotEmpty) return;
    try {
      final pos = await initial;
      final controller = _controller;
      if (controller != null) {
        unawaited(
          controller.animateCamera(
            CameraUpdate.newLatLng(LatLng(pos.latitude, pos.longitude)),
          ),
        );
      }
    } on Object catch (e, s) {
      CrashReporter.record(e, s);
    }
  }

  /// User-triggered recenter: always requests a fresh fix, unlike the shared
  /// one-shot [_initialPosition] used during map init.
  Future<void> _moveToCurrentLocation() async {
    if (mounted) setState(() => _locating = true);
    try {
      final pos = await LocationService.instance.currentPosition();
      final controller = _controller;
      if (controller != null) {
        unawaited(
          controller.animateCamera(
            CameraUpdate.newLatLng(LatLng(pos.latitude, pos.longitude)),
          ),
        );
      }
    } on Object catch (e, s) {
      CrashReporter.record(e, s);
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  void _recenterMap() {
    unawaited(_moveToCurrentLocation());
  }

  Future<void> _autoSelectMemberAtRider(List<BusStationMember> members) async {
    if (_bloc.state.selectedStationUid != null) return;
    final fix = await LocationService.instance.lastKnownPosition();
    if (!mounted ||
        fix == null ||
        !usableAutoFocusFix(
          fix,
          maxAccuracyMeters: _kMemberAccuracyMeters,
          now: DateTime.now().toUtc(),
        )) {
      return;
    }
    final member = nearestWithin(
      members,
      lat: fix.latitude,
      lon: fix.longitude,
      radiusMeters: _kMemberRadiusMeters,
      latOf: (m) => m.lat,
      lonOf: (m) => m.lon,
    );
    // The rider may have picked a pole themselves while the fix was in flight.
    if (member == null || _bloc.state.selectedStationUid != null) return;
    _bloc.add(BusStopStationSelected(member.stationUid));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // Single BusStopBloc instance, shared by the map (marker layer below) and
    // the BusStopDetailView sheet — see class doc on BusStopDetailView.bloc.
    return BlocProvider<BusStopBloc>.value(
      value: _bloc,
      child: Scaffold(
        resizeToAvoidBottomInset: false,
        body: Stack(
          children: [
            Positioned.fill(
              child: BlocConsumer<BusStopBloc, BusStopState>(
                listenWhen: (prev, next) =>
                    prev.members.isEmpty && next.members.isNotEmpty,
                listener: (context, state) {
                  final first = state.members.first;
                  unawaited(
                    _controller?.animateCamera(
                      CameraUpdate.newLatLng(LatLng(first.lat, first.lon)),
                    ),
                  );
                  unawaited(_autoSelectMemberAtRider(state.members));
                },
                buildWhen: (prev, next) => prev.members != next.members,
                builder: (context, state) {
                  final hint = _hint;
                  final target = state.members.isEmpty
                      ? (hint ?? _kDefaultPos)
                      : LatLng(
                          state.members.first.lat,
                          state.members.first.lon,
                        );
                  return GoogleMap(
                    style: mapStyleOf(context),
                    initialCameraPosition: CameraPosition(
                      target: target,
                      zoom: 16,
                    ),
                    markers: {
                      // Stand-in pin so the stop is visible immediately; the
                      // real member markers replace it when they arrive.
                      if (state.members.isEmpty && hint != null)
                        Marker(
                          markerId: const MarkerId('_hint'),
                          position: hint,
                          icon: _busIcon ?? BitmapDescriptor.defaultMarker,
                          anchor: const Offset(0.5, 0.5),
                          infoWindow: InfoWindow(title: widget.stopName),
                        ),
                      for (final m in state.members)
                        Marker(
                          markerId: MarkerId(m.stationUid),
                          position: LatLng(m.lat, m.lon),
                          icon: _busIcon ?? BitmapDescriptor.defaultMarker,
                          anchor: const Offset(0.5, 0.5),
                          infoWindow: InfoWindow(title: m.stationName),
                        ),
                    },
                    myLocationEnabled: true,
                    myLocationButtonEnabled: false,
                    zoomControlsEnabled: false,
                    // Map shares a Stack with the draggable sheet; without an
                    // eager recognizer the map loses the gesture arena, so
                    // pan/pinch leak to the sheet instead of moving the map.
                    gestureRecognizers: const {
                      Factory<OneSequenceGestureRecognizer>(
                        EagerGestureRecognizer.new,
                      ),
                    },
                    onMapCreated: (c) {
                      _controller = c;
                      if (state.members.isEmpty && hint == null) {
                        unawaited(_moveToInitialLocation());
                      }
                    },
                  );
                },
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const FloatingAppBar(),
                // Scoped to the routes this stop actually serves: a
                // disruption on a line that doesn't stop here is not this
                // screen's business.
                BlocSelector<BusStopBloc, BusStopState, Set<String>>(
                  selector: (state) =>
                      state.displays.map((d) => d.subRouteUid).toSet(),
                  builder: (context, routeKeys) =>
                      InlineNotice(routeType: 'bus', routeKeys: routeKeys),
                ),
              ],
            ),

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
              child: BusStopDetailView(
                stopName: widget.stopName,
                stopId: widget.stopId,
                city: widget.city,
                bloc: _bloc,
                onFocusStation: _focusStation,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
