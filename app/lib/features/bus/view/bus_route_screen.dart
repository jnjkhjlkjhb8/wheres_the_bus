import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:skeletonizer/skeletonizer.dart';
import 'package:smooth_sheets/smooth_sheets.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:wheres_the_bus/app/theme/app_shadows.dart';
import 'package:wheres_the_bus/app/theme/app_text_styles.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/core/haptics/alight_haptics.dart';
import 'package:wheres_the_bus/core/location/location_service.dart';
import 'package:wheres_the_bus/core/location/nearest_within.dart';
import 'package:wheres_the_bus/data/decoders/fare_decoder.dart';
import 'package:wheres_the_bus/data/models/bus_models.dart';
import 'package:wheres_the_bus/data/models/bus_route_detail.dart';
import 'package:wheres_the_bus/data/models/fare_type.dart';
import 'package:wheres_the_bus/data/models/timeline_stop.dart';
import 'package:wheres_the_bus/data/tracking/journey_session_bloc.dart';
import 'package:wheres_the_bus/data/tracking/journey_session_event.dart';
import 'package:wheres_the_bus/data/tracking/tracking_session.dart';
import 'package:wheres_the_bus/features/bus/bloc/bus_route_bloc.dart';
import 'package:wheres_the_bus/features/bus/bloc/bus_route_event.dart';
import 'package:wheres_the_bus/features/bus/bloc/bus_route_state.dart';
import 'package:wheres_the_bus/features/bus/map/bus_route_overlay.dart';
import 'package:wheres_the_bus/features/bus/widgets/bus_timeline_stops.dart';
import 'package:wheres_the_bus/features/bus/widgets/bus_timetable_day.dart';
import 'package:wheres_the_bus/features/bus/widgets/pinned_bus.dart';
import 'package:wheres_the_bus/features/bus/widgets/track_trigger_stop.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/map/map_color_scheme.dart';
import 'package:wheres_the_bus/shared/motion/app_motion.dart';
import 'package:wheres_the_bus/shared/motion/pressable.dart';
import 'package:wheres_the_bus/shared/widgets/alight_track/alight_confirm_bar.dart';
import 'package:wheres_the_bus/shared/widgets/alight_track/alight_pick_capsule.dart';
import 'package:wheres_the_bus/shared/widgets/alight_track/alight_swipe_row.dart';
import 'package:wheres_the_bus/shared/widgets/app_accordion.dart';
import 'package:wheres_the_bus/shared/widgets/app_bars.dart';
import 'package:wheres_the_bus/shared/widgets/app_card.dart';
import 'package:wheres_the_bus/shared/widgets/app_input.dart';
import 'package:wheres_the_bus/shared/widgets/app_sliding_segment.dart';
import 'package:wheres_the_bus/shared/widgets/bookmark_button.dart';
import 'package:wheres_the_bus/shared/widgets/bottom_sheet_shell.dart';
import 'package:wheres_the_bus/shared/widgets/divider_line.dart';
import 'package:wheres_the_bus/shared/widgets/error_state_view.dart';
import 'package:wheres_the_bus/shared/widgets/fare_preference.dart';
import 'package:wheres_the_bus/shared/widgets/freshness_stamp.dart';
import 'package:wheres_the_bus/shared/widgets/route_tab_bar.dart';
import 'package:wheres_the_bus/shared/widgets/transit_timeline.dart';

part '../widgets/bus_route_chrome_widgets.dart';
part '../widgets/bus_route_data_helpers.dart';
part '../widgets/bus_route_detail_widgets.dart';
part '../widgets/bus_route_fare_widgets.dart';
part '../widgets/bus_route_horizontal_timeline.dart';
part '../widgets/bus_route_sheet_widgets.dart';
part '../widgets/bus_route_stop_list_widgets.dart';
part '../widgets/bus_route_timetable_widgets.dart';

/// How close the rider must be for the route to open on a stop rather than on
/// the whole line. Stops on a route are often only 300–500 m apart, so a wider
/// radius starts picking the neighbouring one.
const _kRouteAutoFocusRadiusMeters = 200.0;

// Horizontal timeline geometry, mirrored from _HorizontalRouteTimeline so the
// screen can compute a scroll offset without laying the strip out first.
const double _kTlCellWidth = 120;
const double _kTlPadding = AppTheme.space20;

const _kDefaultCamera = CameraPosition(
  target: LatLng(25.0416, 121.5501),
  zoom: 14,
);

// Route sheet drops the shared grid's half detent: at half the timeline is
// already fully visible and the tab content below it is still cut off, so the
// stop is a stall on the way to full rather than a height anyone rests at.
const _kRouteSnapGrid = SheetSnapGrid(
  snaps: [AppSheetSnap.peek, AppSheetSnap.full],
  minFlingSpeed: AppSheetSnap.flingSpeed,
);

class BusRouteScreen extends StatefulWidget {
  const BusRouteScreen({required this.subRouteUid, super.key});
  final String subRouteUid;

  @override
  State<BusRouteScreen> createState() => _BusRouteScreenState();
}

class _BusRouteScreenState extends State<BusRouteScreen>
    with TickerProviderStateMixin {
  // Owned here (not created inside build's BlocProvider) so State methods can
  // reach it directly. A BlocProvider in build() sits below this State element,
  // so a context.read from here would fail the ancestor lookup.
  late final BusRouteBloc _bloc;
  late final TabController _tabController;
  late final SheetController _sheetController;
  final _scrollController = ScrollController();
  // The horizontal timeline (collapsed sheet) is a separate scrollable from the
  // vertical stop list, so a marker tap must drive its own controller too.
  final _timelineController = ScrollController();
  GoogleMapController? _mapController;

  /// Stop uids of the current direction, in list order — lets a marker tap map
  /// a stopUid to its row index for scroll-to.
  List<String> _stopUidsInOrder = const [];

  /// The stop briefly highlighted after its marker was tapped; cleared by
  /// [_flashTimer] after a few seconds.
  String? _flashStopUid;
  Timer? _flashTimer;

  /// Drives the visible bubbles' GPS-freshness clock. Alive only while at least
  /// one bubble is on screen — see [_syncBubbleTicker].
  Timer? _bubbleTicker;

  /// The one stop showing its name as a capsule on the map. Outlives
  /// [_flashStopUid]'s few seconds — a name you are still reading shouldn't
  /// expire — and is cleared by tapping the marker again or the bare map.
  String? _selectedStopUid;

  String? _pinnedPlate;
  bool _pickingStop = false;
  int? _pinnedNextStopIndex;
  String? _targetStopUid;
  int _leadStops = 0;

  final ValueNotifier<BusMapLayer> _mapLayer = ValueNotifier(
    (markers: <Marker>{}, polylines: <Polyline>{}),
  );

  /// Owns everything pinned to a coordinate: the frame signature, the marker
  /// and geometry caches, the in-flight glides, and the supersede rule.
  late final BusRouteOverlay _overlay = BusRouteOverlay(
    onStopTap: _flashStop,
    onVehicleTap: _togglePin,
  );
  bool _fitted = false;

  /// The one cached fix the opening camera is decided from — see [_maybeFit].
  /// Held so a rebuild that re-enters the decision reuses the same answer.
  Future<Position?>? _autoFocusFix;
  // didChangeDependencies fires for reasons other than a brightness flip (text
  // scale, locale, ...); this tracks the last-seen value so only an actual
  // light/dark change forces a resync.
  Brightness? _lastBrightness;
  // Sampled at 12pt, the size the marker bitmaps are scaled from.
  double? _lastTextScale;

  // Vehicle markers slide between live frames; stops/polylines stay static, so
  // a glide tick only repaints the bus + bubble layer on top of them.
  late final AnimationController _busGlide;
  late final CurvedAnimation _busGlideCurve;

  @override
  void initState() {
    super.initState();
    _bloc = BusRouteBloc(subRouteUid: widget.subRouteUid);
    _tabController = TabController(length: 2, vsync: this);
    _sheetController = SheetController();
    // 800ms reads as a bus catching up to its reported spot; a UI-chrome-speed
    // glide (~200ms) would look like a twitch every 30 s.
    _busGlide = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..addListener(_paintVehicles);
    _busGlideCurve = CurvedAnimation(
      parent: _busGlide,
      curve: AppMotion.easeInOut,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final brightness = Theme.of(context).colorScheme.brightness;
    final textScale = MediaQuery.textScalerOf(context).scale(12);
    if ((_lastBrightness != null && _lastBrightness != brightness) ||
        (_lastTextScale != null && _lastTextScale != textScale)) {
      _overlay.invalidate();
      unawaited(_syncMap(_bloc.state));
    }
    _lastBrightness = brightness;
    _lastTextScale = textScale;
  }

  Future<void> _syncMap(BusRouteState s) async {
    // Read before the first await: every caller reaches this from
    // didChangeDependencies or later, so the locale and theme are readable
    // here, and holding them avoids touching `context` across an async gap.
    final i18n = AppI18n.of(context);
    final colors = Theme.of(context).colorScheme;
    final reduceMotion = MediaQuery.of(context).disableAnimations;

    final frame = await _overlay.resolve(
      state: s,
      i18n: i18n,
      colors: colors,
      glideProgress: _busGlideCurve.value,
      now: DateTime.now(),
      selectedStopUid: _selectedStopUid,
      pinnedPlate: _pinnedPlate,
      trackedPlate: context.read<JourneySessionBloc>().state.plate,
      pickingStop: _pickingStop,
    );
    if (frame == null || !mounted) return;

    _stopUidsInOrder = [
      for (final st in _currentStops(s)) st.stopUid,
    ];
    _syncBubbleTicker(wanted: frame.showsAnyBubble);

    if (reduceMotion) {
      // Reduce-motion: snap to the reported position, no glide.
      _busGlide.value = 1;
      _paintVehicles();
    } else {
      // Glide from the current position to the new frame. A frame that didn't
      // move a bus just animates target→target (static); a frame landing
      // mid-glide retargets smoothly because `from` is the live position.
      unawaited(_busGlide.forward(from: 0));
    }
    unawaited(_maybeFit(s));
  }

  void _syncBubbleTicker({required bool wanted}) {
    if (wanted == (_bubbleTicker != null)) return;
    _bubbleTicker?.cancel();
    _bubbleTicker = !wanted
        ? null
        : Timer.periodic(
            const Duration(seconds: 1),
            (_) => unawaited(_tickBubbles()),
          );
  }

  Future<void> _tickBubbles() async {
    if (await _overlay.tickBubbles(DateTime.now()) && mounted) {
      _paintVehicles();
    }
  }

  // Composes the animated bus + bubble markers over the static stop layer and
  // pushes them to the GoogleMap notifier. Runs per glide tick; the sprite and
  // bubble bitmaps are memoized upstream, so a tick is cheap position churn.
  void _paintVehicles() {
    _mapLayer.value = _overlay.paint(
      glideProgress: _busGlideCurve.value,
      pinnedPlate: _pinnedPlate,
    );
  }

  Future<void> _maybeFit(BusRouteState s) async {
    if (_fitted) return;
    if (_mapController == null || _overlay.stopPoints.isEmpty) return;
    _fitted = true;
    final stop = await _nearestStopOnEntry(s);
    final c = _mapController;
    if (!mounted || c == null) return;
    if (stop == null) {
      unawaited(c.animateCamera(_fitUpdate()));
      return;
    }
    unawaited(
      c.animateCamera(
        CameraUpdate.newLatLngZoom(LatLng(stop.lat, stop.lon), 16),
      ),
    );
    // After a frame: the sheet's stop list and horizontal timeline have to be
    // laid out before their controllers can be scrolled to the stop.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _flashStop(stop.stopUid, moveCamera: false);
    });
  }

  Future<BusStopModel?> _nearestStopOnEntry(BusRouteState s) async {
    final fix = await (_autoFocusFix ??= LocationService.instance
        .lastKnownPosition());
    if (fix == null ||
        !usableAutoFocusFix(
          fix,
          maxAccuracyMeters: _kRouteAutoFocusRadiusMeters,
          now: DateTime.now().toUtc(),
        )) {
      return null;
    }
    return nearestWithin(
      _currentStops(s),
      lat: fix.latitude,
      lon: fix.longitude,
      radiusMeters: _kRouteAutoFocusRadiusMeters,
      latOf: (stop) => stop.lat,
      lonOf: (stop) => stop.lon,
    );
  }

  CameraUpdate _fitUpdate() => _overlay.stopPoints.length == 1
      ? CameraUpdate.newLatLngZoom(_overlay.stopPoints.first, 16)
      : CameraUpdate.newLatLngBounds(boundsOf(_overlay.stopPoints), 60);

  void _recenterMap() {
    final controller = _mapController;
    if (controller != null) {
      unawaited(
        controller.animateCamera(
          _overlay.stopPoints.isEmpty
              ? CameraUpdate.newCameraPosition(_kDefaultCamera)
              : _fitUpdate(),
        ),
      );
    }
  }

  void _flashStop(String stopUid, {bool moveCamera = true}) {
    final selecting = _selectedStopUid != stopUid;
    _selectStop(selecting ? stopUid : null);
    final index = _stopUidsInOrder.indexOf(stopUid);
    if (index >= 0) {
      _scrollListTo(index);
      // The stop's own cell: its dot sits at the centre of cell `index`.
      _scrollTimelineTo(index * _kTlCellWidth + _kTlCellWidth / 2);
    }
    // Deselecting is a dismissal — the rider closed the capsule, so leave the
    // camera where they left it.
    if (moveCamera && selecting) {
      final stop = _currentStops(
        _bloc.state,
      ).where((st) => st.stopUid == stopUid).firstOrNull;
      if (stop != null && (stop.lat != 0 || stop.lon != 0)) {
        _focusCameraOn(LatLng(stop.lat, stop.lon));
      }
    }
    _flashTimer?.cancel();
    setState(() => _flashStopUid = stopUid);
    _flashTimer = Timer(const Duration(milliseconds: 2500), () {
      if (mounted) setState(() => _flashStopUid = null);
    });
  }

  void _scrollListTo(int index) {
    if (!_scrollController.hasClients) return;
    const estRowHeight = 54.0;
    final target = (index * estRowHeight).clamp(
      0.0,
      _scrollController.position.maxScrollExtent,
    );
    unawaited(
      _scrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 320),
        curve: AppMotion.easeInOut,
      ),
    );
  }

  /// Centres the horizontal timeline on [contentX], an x in the strip's own
  /// content coordinates (cells are a fixed width, so callers can compute one
  /// exactly — a stop's dot, or the boundary a vehicle arrow rides).
  void _scrollTimelineTo(double contentX) {
    if (!_timelineController.hasClients) return;
    final pos = _timelineController.position;
    final target = (contentX + _kTlPadding - pos.viewportDimension / 2).clamp(
      0.0,
      pos.maxScrollExtent,
    );
    unawaited(
      _timelineController.animateTo(
        target,
        duration: const Duration(milliseconds: 320),
        curve: AppMotion.easeInOut,
      ),
    );
  }

  /// Aims the map at one marker. Same zoom the route uses when it opens on the
  /// rider's own stop, so tapping a stop in the sheet and arriving on one from
  /// outside land the rider at the same scale.
  void _focusCameraOn(LatLng target) {
    unawaited(
      _mapController?.animateCamera(CameraUpdate.newLatLngZoom(target, 16)) ??
          Future<void>.value(),
    );
  }

  void _selectStop(String? stopUid) {
    if (_selectedStopUid == stopUid) return;
    _selectedStopUid = stopUid;
    _repaintPins();
  }

  void _cancelPick() {
    context.read<JourneySessionBloc>().add(
      const JourneyCancelled(userInitiated: true),
    );
    setState(() {
      _pinnedPlate = null;
      _pickingStop = false;
      _pinnedNextStopIndex = null;
      _targetStopUid = null;
    });
    _repaintPins();
    _liftSheet(false);
  }

  void _togglePin(String plate) {
    if (_pinnedPlate == plate) {
      _clearPin();
      return;
    }
    final s = _bloc.state;
    // Snapshot the bus's position now, so that if the rider does go on to pick
    // an alight stop the passed/downstream split holds still rather than
    // shifting under each live frame.
    final nextStopIndex = pinnedBusNextStopIndex(
      etas: s.etaMap.values,
      stopUidsInOrder: _stopUidsInOrder,
      direction: s.direction,
      plate: plate,
    );
    setState(() {
      _pinnedPlate = plate;
      _pinnedNextStopIndex = nextStopIndex;
    });
    _repaintPins();
    final at = _overlay.vehiclePosition(plate);
    if (at != null) _focusCameraOn(at);
    if (nextStopIndex != null) {
      // The bus's own mark, not the stop it is heading for: in the list it is
      // the marker row above row `nextStopIndex`, and in the strip it rides
      // the boundary on that cell's left edge.
      _scrollListTo(nextStopIndex);
      _scrollTimelineTo(nextStopIndex * _kTlCellWidth);
    }
  }

  void _clearPin() {
    setState(() {
      _pinnedPlate = null;
      _pinnedNextStopIndex = null;
    });
    _repaintPins();
  }

  void _liftSheet(bool picking) => unawaited(
    _sheetController.animateToDetent(
      picking ? AppSheetSnap.full : AppSheetSnap.peek,
      reduced: AppMotion.reduced(context),
    ),
  );

  // Pin state lives in [State], not the map signature, so a select/confirm
  // repaints the bus bubbles (glyph + dim) by forcing [_syncMap] to rebuild.
  void _repaintPins() {
    unawaited(_syncMap(_bloc.state));
  }

  void _enterPickFromSwipe(String plate, int markerIndex) {
    setState(() {
      _pinnedPlate = plate;
      _pickingStop = true;
      // The marker sits between the stop the bus just passed and the one it is
      // heading for, so its own index is that next stop — the same snapshot
      // _togglePin takes, held still for the rest of the flow.
      _pinnedNextStopIndex = markerIndex;
      _targetStopUid = null;
      _leadStops = 0;
    });
    _repaintPins();
    _liftSheet(true);
  }

  /// The confirm bar for an open bus flow: how many stops of warning, and the
  /// commit. It carries no binding row — the swipe that opened the flow named
  /// the vehicle, so there is nothing here for the rider to settle.
  Widget _buildAlightConfirmBar(BuildContext context, BusRouteState state) {
    final stops = _currentStops(state);
    final target = _targetStopUid;
    final targetStop = stops.where((s) => s.stopUid == target).firstOrNull;
    if (targetStop == null) return const SizedBox.shrink();
    return AlightConfirmBar(
      targetName: targetStop.stopName,
      lead: _leadStops,
      onLeadChanged: (v) => setState(() => _leadStops = clampLeadStops(v)),
      onRepick: () => setState(() => _targetStopUid = null),
      onCancel: _cancelPick,
      onStart: _confirmPick,
      canStart: _pinnedPlate != null,
    );
  }

  void _onPickStop(String uid) {
    setState(() => _targetStopUid = uid);
  }

  String? get _leadStopUid {
    final target = _targetStopUid;
    if (target == null || _leadStops <= 0) return null;
    final trigger = resolveTriggerStopUid(_stopUidsInOrder, target, _leadStops);
    return trigger == target ? null : trigger;
  }

  /// The plate a running 下車提醒 on this subroute follows, so the stop list
  /// can mark that vehicle's row. Null for another route's session, or none.
  String? _boundPlate(BuildContext context) {
    final session = context.watch<JourneySessionBloc>().state;
    if (trackedBusStopUid(session, _bloc.subRouteUid) == null) return null;
    return session.plate;
  }

  /// The current direction's stops, or empty when the route isn't loaded.
  List<BusStopModel> _currentStops(BusRouteState s) {
    final route = s.route;
    if (route == null) return const [];
    return s.direction == 0 ? route.stopsGo : route.stopsReturn;
  }

  void _confirmPick() {
    final plate = _pinnedPlate;
    final target = _targetStopUid;
    if (plate == null || target == null) return;
    final s = _bloc.state;
    final route = s.route;
    if (route == null) return;
    final stops = _currentStops(s);
    final idx = stops.indexWhere((st) => st.stopUid == target);
    if (idx < 0) return;
    context.read<JourneySessionBloc>().add(
      JourneyStarted(
        trackOnly: true,
        plate: plate,
        legs: [
          busTrackingLeg(
            route: route,
            stops: stops,
            boardIndex: _pinnedNextStopIndex ?? -1,
            targetIndex: idx,
            direction: s.direction,
          ),
        ],
        // The same 提前站數 that arms the reminder below also decides where the
        // tracking card's bar turns warm. Without it the card would fall back
        // to its default and warn at a different stop than the rider set.
        leadStops: _leadStops,
      ),
    );
    _bloc.add(
      BusRoutePinnedReminderArmed(
        stopUid: target,
        plate: plate,
        event: AlightEvent.alight,
      ),
    );
    if (_leadStops > 0) {
      final trigger = resolveTriggerStopUid(
        _stopUidsInOrder,
        target,
        _leadStops,
      );
      // A lead that resolves back onto the 下車站 (the bus is already inside
      // the lead window) would arm the same stop twice; the bloc's own
      // already-armed guard drops it, but not asking is clearer.
      if (trigger != target) {
        _bloc.add(
          BusRoutePinnedReminderArmed(
            stopUid: trigger,
            plate: plate,
            event: AlightEvent.lead,
          ),
        );
      }
    }
    setState(() => _pickingStop = false);
    _repaintPins();
    _liftSheet(false);
  }

  @override
  void dispose() {
    _flashTimer?.cancel();
    _bubbleTicker?.cancel();
    _busGlideCurve.dispose();
    _busGlide.dispose();
    _tabController.dispose();
    _sheetController.dispose();
    _scrollController.dispose();
    _timelineController.dispose();
    _mapLayer.dispose();
    unawaited(_bloc.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    final sheetAnimation = SheetOffsetDrivenAnimation(
      controller: _sheetController,
      initialValue: 0,
    );

    final sheetPeekPx =
        MediaQuery.sizeOf(context).height * AppSheetSnap.peekFrac;

    return BlocProvider<BusRouteBloc>.value(
      value: _bloc,
      child: BlocConsumer<BusRouteBloc, BusRouteState>(
        // etaMap is deliberately excluded: live ETA frames must not rebuild the
        // static chrome (map, app bar, FAB, sheet skeleton). ETA-consuming
        // subtrees observe etaMap through their own BlocSelectors instead.
        buildWhen: (prev, curr) =>
            prev.route != curr.route ||
            prev.direction != curr.direction ||
            prev.fare != curr.fare ||
            prev.bufferSequences != curr.bufferSequences ||
            prev.daily != curr.daily ||
            prev.loading != curr.loading ||
            prev.error != curr.error,
        listener: (context, state) => _syncMap(state),
        builder: (context, state) {
          final routeName = state.route?.routeName ?? '';
          final dirNames = [
            state.route?.headsignGo ?? '',
            state.route?.headsignReturn ?? '',
          ];
          final dirName = state.direction == 0 ? dirNames[0] : dirNames[1];

          return ValueListenableBuilder<double?>(
            valueListenable: _sheetController,
            builder: (context, offset, child) {
              // minOffset rather than the peek fraction: the resting detent is
              // the pick offset mid-pick, and metrics stay honest either way.
              final metrics = _sheetController.metrics;
              final atRest =
                  metrics == null ||
                  offset == null ||
                  offset <= metrics.minOffset + 1;
              return PopScope(
                canPop: atRest,
                onPopInvokedWithResult: (didPop, _) {
                  if (!didPop) _liftSheet(_pickingStop);
                },
                child: child!,
              );
            },
            child: Scaffold(
              resizeToAvoidBottomInset: false,
              body: Stack(
                children: [
                  Positioned.fill(
                    child: ValueListenableBuilder<BusMapLayer>(
                      valueListenable: _mapLayer,
                      builder: (context, layer, _) => GoogleMap(
                        style: mapStyleOf(context),
                        initialCameraPosition: _kDefaultCamera,
                        myLocationEnabled: true,
                        myLocationButtonEnabled: false,
                        zoomControlsEnabled: false,
                        mapToolbarEnabled: false,
                        compassEnabled: false,
                        markers: layer.markers,
                        polylines: layer.polylines,
                        padding: EdgeInsets.only(bottom: sheetPeekPx),
                        // Map shares a Stack with the draggable sheet; without
                        // an eager recognizer the map loses the gesture arena,
                        // so pan/pinch leak to the sheet instead of the map.
                        gestureRecognizers: const {
                          Factory<OneSequenceGestureRecognizer>(
                            EagerGestureRecognizer.new,
                          ),
                        },
                        // The marker toggles its own capsule, but a rider who
                        // has moved on shouldn't have to find it again to
                        // close it.
                        onTap: (_) => _selectStop(null),
                        onMapCreated: (controller) {
                          _mapController = controller;
                          unawaited(_maybeFit(_bloc.state));
                        },
                      ),
                    ),
                  ),

                  if (state.error != null)
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      bottom: sheetPeekPx,
                      child: AnimatedBuilder(
                        animation: sheetAnimation,
                        builder: (context, child) {
                          // Mirrors the timeline's own fade curve in
                          // _RouteSheet so this recedes as the sheet rises past
                          // peek, instead of lingering behind it.
                          final progress = sheetAnimation.value;
                          final opacity = (1.0 - progress * 1.6).clamp(
                            0.0,
                            1.0,
                          );
                          return Opacity(
                            opacity: opacity,
                            child: IgnorePointer(
                              ignoring: progress > 0.5,
                              child: child,
                            ),
                          );
                        },
                        child: ColoredBox(
                          color: cs.surface,
                          child: SafeArea(
                            bottom: false,
                            // Clears the floating app bar row (44px buttons +
                            // 8px top/bottom padding) so back/bookmark stay
                            // reachable.
                            child: Padding(
                              padding: const EdgeInsets.only(top: 60),
                              child: ErrorStateView(
                                error: state.error!,
                                onRetry: () => context.read<BusRouteBloc>().add(
                                  const BusRouteStarted(),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),

                  _FloatingAppBar(
                    subRouteUid: widget.subRouteUid,
                    routeName: routeName,
                    dirName: dirName,
                    direction: state.direction,
                  ),

                  if (state.error == null)
                    ValueListenableBuilder<double?>(
                      valueListenable: _sheetController,
                      builder: (context, offset, child) {
                        final currentOffset = offset ?? 0.0;
                        const fadeRange = 80.0;
                        final overshoot = currentOffset - sheetPeekPx;
                        final opacity = (1.0 - overshoot / fadeRange).clamp(
                          0.0,
                          1.0,
                        );
                        return Positioned(
                          right: 16,
                          bottom: currentOffset.clamp(0.0, sheetPeekPx) + 16,
                          child: IgnorePointer(
                            ignoring: opacity == 0,
                            child: Opacity(opacity: opacity, child: child),
                          ),
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
                            child: Icon(
                              Icons.gps_fixed_rounded,
                              size: 20,
                              color: cs.onSurface,
                            ),
                          ),
                        ),
                      ),
                    ),

                  _RouteSheet(
                    tabController: _tabController,
                    sheetController: _sheetController,
                    scrollController: _scrollController,
                    timelineController: _timelineController,
                    flashStopUid: _flashStopUid,
                    direction: state.direction,
                    isLoading: state.loading,
                    onDirectionChanged: (dir) {
                      if (state.direction == dir) return;
                      context.read<BusRouteBloc>().add(
                        BusRouteDirectionToggled(dir),
                      );
                      if (_scrollController.hasClients) {
                        _scrollController.jumpTo(0);
                      }
                    },
                    sheetAnimation: sheetAnimation,
                    routeName: routeName,
                    dirNames: dirNames,
                    routeState: state,
                    pickingStop: _pickingStop,
                    pinnedNextStopIndex: _pinnedNextStopIndex,
                    targetStopUid: _targetStopUid,
                    leadStopUid: _leadStopUid,
                    boundPlate: _boundPlate(context),
                    onPickStop: _onPickStop,
                    onSwipeVehicle: _enterPickFromSwipe,
                    onCancelPick: _cancelPick,
                    onTapStop: _flashStop,
                    onTapVehicle: _togglePin,
                  ),

                  if (_pickingStop && _targetStopUid != null)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: _buildAlightConfirmBar(context, state),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
