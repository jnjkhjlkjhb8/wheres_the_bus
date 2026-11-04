import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:skeletonizer/skeletonizer.dart';
import 'package:smooth_sheets/smooth_sheets.dart';
import 'package:wheres_the_bus/app/router/app_routes.dart';
import 'package:wheres_the_bus/app/theme/app_shadows.dart';
import 'package:wheres_the_bus/app/theme/app_text_styles.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/core/haptics/haptic_service.dart';
import 'package:wheres_the_bus/core/location/location_service.dart';
import 'package:wheres_the_bus/data/models/plan_models.dart';
import 'package:wheres_the_bus/data/models/plan_options.dart';
import 'package:wheres_the_bus/data/repositories/maas_repository.dart';
import 'package:wheres_the_bus/data/repositories/planner_repository.dart';
import 'package:wheres_the_bus/data/repositories/settings_repository.dart';
import 'package:wheres_the_bus/data/tracking/journey_session_bloc.dart';
import 'package:wheres_the_bus/data/tracking/journey_session_state.dart';
import 'package:wheres_the_bus/features/go/bloc/plan_bloc.dart';
import 'package:wheres_the_bus/features/go/bloc/plan_event.dart';
import 'package:wheres_the_bus/features/go/bloc/plan_state.dart';
import 'package:wheres_the_bus/features/go/map/go_plan_overlay.dart';
import 'package:wheres_the_bus/features/go/model/planned_place.dart';
import 'package:wheres_the_bus/features/go/navigation/navigation_coordinator.dart';
import 'package:wheres_the_bus/features/go/view/place_search_screen.dart';
import 'package:wheres_the_bus/features/go/widgets/route_option_card.dart';
import 'package:wheres_the_bus/features/go/widgets/transit_visuals.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/map/map_color_scheme.dart';
import 'package:wheres_the_bus/shared/map/motion_aware_camera.dart';
import 'package:wheres_the_bus/shared/motion/app_motion.dart';
import 'package:wheres_the_bus/shared/motion/pressable.dart';
import 'package:wheres_the_bus/shared/widgets/app_badge.dart';
import 'package:wheres_the_bus/shared/widgets/app_bars.dart';
import 'package:wheres_the_bus/shared/widgets/app_button.dart';
import 'package:wheres_the_bus/shared/widgets/app_date_picker.dart';
import 'package:wheres_the_bus/shared/widgets/app_quantity_selector.dart';
import 'package:wheres_the_bus/shared/widgets/app_range_slider.dart';
import 'package:wheres_the_bus/shared/widgets/app_slider.dart';
import 'package:wheres_the_bus/shared/widgets/app_sliding_segment.dart';
import 'package:wheres_the_bus/shared/widgets/app_snackbar.dart';
import 'package:wheres_the_bus/shared/widgets/app_spinner.dart';
import 'package:wheres_the_bus/shared/widgets/app_switch.dart';
import 'package:wheres_the_bus/shared/widgets/app_time_picker.dart';
import 'package:wheres_the_bus/shared/widgets/bottom_sheet_shell.dart';
import 'package:wheres_the_bus/shared/widgets/divider_line.dart';
import 'package:wheres_the_bus/shared/widgets/filter_chip_group.dart';

part 'go_screen_camera.dart';
part '../widgets/go_navigation_widgets.dart';
part '../widgets/go_planner_time_widgets.dart';
part '../widgets/go_planner_waiting_widgets.dart';
part '../widgets/go_planner_widgets.dart';
part '../widgets/go_preview_widgets.dart';

const _kDefaultPos = LatLng(25.0416, 121.5438);

// Muted gray for non-selected alternate routes on the map. A fixed neutral
// (rather than a theme color) so it reads as clearly secondary over both the
// light and dark map styles.

const _kNavZoom = 15.5;
const _kNavTilt = 45.0;
const _kNavBearing = 30.0;

enum _TimeMode { leaveNow, departAt, arriveBy }

class GoScreen extends StatefulWidget {
  const GoScreen({super.key, this.initialDestination, this.plannerRepository});

  /// A destination handed in by whoever opened the planner (a station detail
  /// saying "take me here"). The origin still resolves from GPS, so the plan
  /// fires on its own as soon as that lands — see [_GoScreenState._initOrigin].
  final PlannedPlace? initialDestination;
  final PlannerRepository? plannerRepository;

  @override
  State<GoScreen> createState() => _GoScreenState();
}

class _GoScreenState extends State<GoScreen> {
  GoogleMapController? _map;
  late final SheetController _sheet;
  late final SheetController _previewSheet;
  late final NavigationCoordinator _navigationCoordinator;
  PlannedPlace? _origin;
  // Whether the GPS fix that fills the origin is still coming, arrived, or was
  // refused — the field says which rather than showing an unfilled hint that
  // reads like a required choice.
  OriginStatus _originStatus = OriginStatus.resolving;
  PlannedPlace? _dest;
  PlanOptions _options = const PlanOptions();
  // What the live planner honours. Starts at the five core options, so
  // the options sheet is never empty and never offers a control that silently
  // does nothing; the real answer replaces it as soon as /api/planner responds.
  PlannerCapabilities _capabilities = const PlannerCapabilities.shared();
  // Departure/arrival time stance for the query. `_timeAt` is only consulted
  // when `_timeMode` is not `leaveNow`.
  _TimeMode _timeMode = _TimeMode.leaveNow;
  DateTime _timeAt = DateTime.now();
  bool _followPaused = false;
  double _puckHeading = _kNavBearing;
  // Most recent navigation GPS fix, cached so the recenter button can snap the
  // camera back to the user, and so the puck can be placed at the user.
  Position? _lastFix;
  // Compass heading subscription — magnetometer draws battery, so it lives only
  // for the duration of an active navigation (started with follow, torn down at
  // nav end / dispose), never on the planner screen.
  // The subscription is cancelled by _stopCompass on every navigation end and
  // again from dispose for a route removed while navigation is active.
  // ignore: cancel_subscriptions
  StreamSubscription<double>? _compassSub;
  // Last compass heading actually applied to the puck, plus when — feeds the
  // shouldApplyHeading throttle.
  double? _lastAppliedHeading;
  DateTime _lastHeadingApplied = DateTime.fromMillisecondsSinceEpoch(0);
  // onCameraMoveStarted fires for the app's own animateCamera too; this counts
  // in-flight programmatic moves so only genuine user gestures pause follow.
  int _programmaticMoves = 0;
  DateTime _lastProgrammaticMove = DateTime.fromMillisecondsSinceEpoch(0);
  static const _kProgrammaticMoveGrace = Duration(milliseconds: 500);

  late final GoPlanOverlay _overlay = GoPlanOverlay(
    onAlternateTap: _previewRouteIndex,
    onPuckTap: _recenterFollow,
    onBitmapReady: () => setState(() {}),
  );

  /// The layer the map is currently showing, recomputed in build.
  GoMapLayer _layer = (markers: const {}, polylines: const {});

  @override
  void initState() {
    super.initState();
    _dest = widget.initialDestination;
    _sheet = SheetController();
    _previewSheet = SheetController();
    _navigationCoordinator = NavigationCoordinator(
      planBloc: context.read<PlanBloc>(),
      journeySessionBloc: context.read<JourneySessionBloc>(),
      liveActivityEnabled: () =>
          SettingsRepository.instance.liveActivityEnabled,
      positions: LocationService.instance.navigationStream,
      onAutoAction: _onAutoNavAction,
      onFollowUpdate: _onFollowUpdate,
    );
    if (context.read<PlanBloc>().state.activeLegIndex == null) {
      unawaited(_initOrigin());
    }
    unawaited(_loadCapabilities());
  }

  /// Asks the router which planner is live. Failure is not surfaced: the
  /// repository already degrades to the shared five, and a rider opening the
  /// planner has no use for the news that a capability probe timed out.
  Future<void> _loadCapabilities() async {
    final capabilities =
        await (widget.plannerRepository ?? PlannerRepository.instance)
            .capabilities();
    if (mounted) setState(() => _capabilities = capabilities);
  }

  @override
  void dispose() {
    // Pending marker bitmaps must stop repainting before this screen leaves.
    _overlay.dispose();
    _navigationCoordinator.dispose();
    _stopCompass();
    _map?.dispose();
    _sheet.dispose();
    _previewSheet.dispose();
    super.dispose();
  }

  Future<void> _initOrigin() async {
    if (mounted) setState(() => _originStatus = OriginStatus.resolving);
    await Future<void>.microtask(() {});
    if (!mounted) return;
    final i18n = AppI18n.of(context);
    try {
      final place = await resolveCurrentPlace(i18n);
      _acceptOrigin(place);
    } on Object catch (_) {
      _markOriginUnavailable();
    }
  }

  void _acceptOrigin(PlannedPlace place) {
    if (!mounted) return;
    setState(() {
      _origin = place;
      _originStatus = OriginStatus.resolved;
    });
    _maybePlan();
  }

  void _markOriginUnavailable() {
    if (!mounted) return;
    setState(() => _originStatus = OriginStatus.unavailable);
  }

  Future<void> _editField({required bool origin}) async {
    final picked = await showPlaceSearchPage(
      context,
      fieldLabel: _fieldLabel(origin),
    );
    if (picked == null || !mounted) return;
    setState(() => _setPlace(picked, origin: origin));
    _maybePlan();
  }

  String _fieldLabel(bool origin) => origin
      ? AppI18n.of(context).goChooseOrigin
      : AppI18n.of(context).goChooseDestination;

  void _setPlace(PlannedPlace picked, {required bool origin}) {
    if (origin) {
      _origin = picked;
      _originStatus = OriginStatus.resolved;
    } else {
      _dest = picked;
    }
  }

  // A destination picked from the plan-entry shortcut list. If the origin isn't
  // resolved yet (GPS pending or denied), don't swallow the pick — send the
  // user to choose an origin first, then plan with both set.
  void _pickDestination(PlannedPlace place) {
    if (_origin == null) {
      unawaited(_resolveOriginThenPlan(place));
      return;
    }
    setState(() => _dest = place);
    _maybePlan();
  }

  Future<void> _resolveOriginThenPlan(PlannedPlace dest) async {
    final picked = await showPlaceSearchPage(
      context,
      fieldLabel: AppI18n.of(context).goChooseOrigin,
    );
    if (picked == null || !mounted) return;
    setState(() {
      _origin = picked;
      _dest = dest;
    });
    _maybePlan();
  }

  void _swap() {
    if (_origin == null && _dest == null) return;
    setState(() {
      final t = _origin;
      _origin = _dest;
      _dest = t;
    });
    _maybePlan();
  }

  void _maybePlan({String pageCursor = ''}) {
    final from = _origin;
    final to = _dest;
    if (from == null || to == null) return;
    // `leaveNow` always resolves a fresh timestamp; the other modes pin the
    // user's chosen instant and set the wire `arriveBy` flag accordingly.
    final when = _queryTime();
    String two(int v) => v.toString().padLeft(2, '0');
    _overlay.invalidate();
    context.read<PlanBloc>().add(
      PlanSearchRequested(
        fromLat: from.latLng.latitude,
        fromLon: from.latLng.longitude,
        toLat: to.latLng.latitude,
        toLon: to.latLng.longitude,
        date: '${when.year}-${two(when.month)}-${two(when.day)}',
        time: '${two(when.hour)}:${two(when.minute)}',
        arriveBy: _timeMode == _TimeMode.arriveBy,
        options: _options.copyWith(
          wheelchair: SettingsRepository.instance.stepFreeRouting,
          walkSpeedCmPerSec: SettingsRepository.instance.walkSpeedCmPerSec,
        ),
        pageCursor: pageCursor,
        legAlternatives: _legAlternatives(),
      ),
    );
  }

  DateTime _queryTime() =>
      _timeMode == _TimeMode.leaveNow ? DateTime.now() : _timeAt;

  int _legAlternatives() =>
      _capabilities.has(PlannerCapabilities.legAlternatives)
      ? _kLegAlternatives
      : 0;

  static const int _kLegAlternatives = 3;

  void _retry() {
    unawaited(HapticService.instance.lightTap());
    _maybePlan();
  }

  void _page(String cursor) {
    if (cursor.isEmpty) return;
    unawaited(HapticService.instance.lightTap());
    _maybePlan(pageCursor: cursor);
  }

  // Give up on a query that is taking too long. The destination is cleared with
  // it so the screen falls back to the entry surface rather than sitting on a
  // map with nothing on it; the origin and the typed options survive.
  void _cancelPlan() {
    unawaited(HapticService.instance.lightTap());
    _clearDestination();
  }

  void _clearDestination() {
    context.read<PlanBloc>().add(const PlanSearchCancelled());
    setState(() => _dest = null);
  }

  // A destination the rider picked here is worth stepping back out of; one the
  // caller handed in (a station's "go here") is the screen's reason to exist,
  // so back from its results returns to that station instead.
  bool get _destinationIsOurs =>
      _dest != null && !identical(_dest, widget.initialDestination);

  PlanRoute? _lastRouteForTrip(List<PlanRoute> saved) {
    final from = _origin?.latLng;
    final to = _dest?.latLng;
    if (from == null || to == null) return null;
    return _matchingSavedRoute(saved, from, to);
  }

  PlanRoute? _matchingSavedRoute(
    List<PlanRoute> saved,
    LatLng from,
    LatLng to,
  ) {
    for (final route in saved) {
      if (_sameTrip(route, from, to)) return route;
    }
    return null;
  }

  bool _sameTrip(PlanRoute route, LatLng from, LatLng to) {
    final sections = route.sections;
    if (sections.isEmpty) return false;
    return _near(from, sections.first.departure.location) &&
        _near(to, sections.last.arrival.location);
  }

  // Within a short walk of the same spot. Loose on purpose: a saved route's
  // ends are the stop it boarded at, not the address that was searched for.
  static const _kSameTripMeters = 400.0;

  double? _straightLineMeters() {
    final from = _origin?.latLng;
    final to = _dest?.latLng;
    if (from == null || to == null) return null;
    return Geolocator.distanceBetween(
      from.latitude,
      from.longitude,
      to.latitude,
      to.longitude,
    );
  }

  bool _near(LatLng a, PlanPoint b) =>
      Geolocator.distanceBetween(a.latitude, a.longitude, b.lat, b.lng) <=
      _kSameTripMeters;

  Future<void> _adjustOptions() async {
    final picked = await showOptionsSheet(
      context,
      current: _options,
      capabilities: _capabilities,
    );
    if (picked == null || !mounted) return;
    _applyOptions(picked);
  }

  void _applyOptions(PlanOptions options) {
    if (options == _options) return;
    setState(() => _options = options);
    _maybePlan();
  }

  Future<void> _adjustTime() async {
    final picked = await _showTimeModeSheet(
      context,
      mode: _timeMode,
      at: _timeAt,
    );
    if (picked == null || !mounted) return;
    // No re-plan when nothing effectively changed (same mode, and — for the
    // timed modes — the same instant).
    _applyTime(picked.mode, picked.at);
  }

  void _applyTime(_TimeMode mode, DateTime at) {
    if (_sameTimeSelection(mode, at)) return;
    setState(() {
      _timeMode = mode;
      _timeAt = at;
    });
    _maybePlan();
  }

  bool _sameTimeSelection(_TimeMode mode, DateTime at) =>
      mode == _timeMode && _sameQueryInstant(mode, at);

  bool _sameQueryInstant(_TimeMode mode, DateTime at) =>
      mode == _TimeMode.leaveNow || at == _timeAt;

  // A results card tap selects the route and enters preview (never navigates).
  void _previewRoute(PlanRoute route) {
    final routes = context.read<PlanBloc>().state.result?.routes ?? const [];
    _previewRouteIndex(routes.indexOf(route));
  }

  // A map alternate-polyline tap selects that route and enters preview.
  void _previewRouteIndex(int index) {
    if (index < 0) return;
    context.read<PlanBloc>().add(RouteSelected(index: index));
  }

  void _closePreview() {
    context.read<PlanBloc>().add(const PreviewClosed());
  }

  // Preview CTA: navigation starts here (the only entry point), so the heavier
  // haptic that used to live on the card tap moves to this commit.
  void _startFromPreview(PlanRoute route, int routeIndex) {
    unawaited(HapticService.instance.heavyTap());
    unawaited(_startNavigation(route: route, routeIndex: routeIndex));
  }

  void _toggleSave(PlanRoute route) {
    unawaited(HapticService.instance.lightTap());
    final bloc = context.read<PlanBloc>();
    final wasSaved = bloc.state.savedKeys.contains(route.savedKey);
    bloc.add(RouteSaveToggled(route));
    // Mirror the favorites-remove undo affordance (see FavoritesScreen).
    if (wasSaved) {
      AppSnackbar.show(
        context,
        AppI18n.of(context).favoritesRemoved,
        action: AppI18n.of(context).commonUndo,
        onAction: () => bloc.add(RouteSaveToggled(route)),
      );
    }
  }

  void _openSaved(PlanRoute route) {
    context.read<PlanBloc>().add(SavedRouteOpened(route));
  }

  Future<void> _startNavigation({
    required PlanRoute route,
    required int routeIndex,
  }) async {
    final start = await _navigationCoordinator.start(
      route: route,
      routeIndex: routeIndex,
    );
    if (!mounted) return;
    // (Re)starting navigation re-arms follow and reseeds the puck heading; the
    // compass then rotates the puck (never the map) as fixes drive the camera.
    setState(() => _followPaused = false);
    _puckHeading = _kNavBearing;
    _lastAppliedHeading = null;
    _startCompass();
    final target = _latLngOrNull(start);
    if (target != null) {
      unawaited(
        _animateCameraGuarded(
          CameraUpdate.newCameraPosition(
            CameraPosition(
              target: target,
              zoom: _kNavZoom,
              bearing: _kNavBearing,
              tilt: _kNavTilt,
            ),
          ),
        ),
      );
    }
  }

  void _onCompassHeading(double heading) {
    if (!mounted) return;
    if (!_canApplyHeading(heading)) return;
    _lastAppliedHeading = heading;
    _lastHeadingApplied = DateTime.now();
    // Rotate the directional puck; heading is north-referenced and the camera
    // stays at _kNavBearing, so no bearing compensation is needed.
    setState(() => _puckHeading = heading);
  }

  bool _canApplyHeading(double heading) =>
      context.read<PlanBloc>().state.activeLegIndex != null &&
      shouldApplyHeading(
        last: _lastAppliedHeading,
        next: heading,
        sinceLast: DateTime.now().difference(_lastHeadingApplied),
      );

  // Each navigation GPS fix. Keeps the camera on the user (tilt/zoom/bearing
  // all fixed — only the target follows) unless the user has panned away.
  void _onFollowUpdate(Position fix) {
    if (!mounted) return;
    // Cache every fix (even while paused) so the recenter button and the puck
    // always have a fresh position.
    _lastFix = fix;
    final navigating = context.read<PlanBloc>().state.activeLegIndex != null;
    // Move the directional puck to the new fix.
    if (navigating) setState(() {});
    _followWhenActive(fix, navigating);
  }

  void _followWhenActive(Position fix, bool navigating) {
    if (!navigating || _followPaused) return;
    _followTo(fix);
  }

  void _followTo(Position fix) {
    // The camera bearing is the fixed _kNavBearing — the map never rotates, so
    // a follow tick only recenters the target.
    unawaited(
      _animateCameraGuarded(
        CameraUpdate.newCameraPosition(
          CameraPosition(
            target: LatLng(fix.latitude, fix.longitude),
            zoom: _kNavZoom,
            bearing: _kNavBearing,
            tilt: _kNavTilt,
          ),
        ),
      ),
    );
  }

  // Puck tap: re-arm follow and snap the camera back to the user.
  void _recenterFollow() {
    unawaited(HapticService.instance.lightTap());
    setState(() => _followPaused = false);
    final fix = _lastFix;
    if (fix != null) _followTo(fix);
  }

  // Autopilot side effect: mirrors the manual buttons' haptic, and (for
  // alight/advance) either the arrival snackbar+camera reset on the final leg
  // or the camera pan to the next leg's departure point.
  void _onAutoNavAction(
    NavAction action,
    PlanPoint? cameraTarget,
    bool arrived,
  ) {
    if (!mounted) return;
    unawaited(HapticService.instance.lightTap());
    if (arrived) {
      _resetCamera();
      AppSnackbar.show(
        context,
        AppI18n.of(context).goArrived,
        type: SnackType.success,
      );
      return;
    }
    // Auto leg advance re-arms follow, mirroring the manual advance path.
    setState(() => _followPaused = false);
    _advanceCameraTarget(cameraTarget);
  }

  void _advanceCameraTarget(PlanPoint? target) {
    final next = _latLngOrNull(target);
    if (next != null) {
      unawaited(_animateCameraGuarded(CameraUpdate.newLatLng(next)));
    }
  }

  void _endNav() {
    unawaited(HapticService.instance.lightTap());
    unawaited(_navigationCoordinator.end());
    _resetCamera();
  }

  Future<void> _reconcileJourneyDone() async {
    final shouldResetCamera = await _navigationCoordinator
        .reconcileJourneyDone();
    if (mounted && shouldResetCamera) _resetCamera();
  }

  void _resetCamera() {
    // Every navigation-end path funnels through here (manual end, auto-arrival,
    // self-completed journey), so release the compass here too.
    _stopCompass();
    unawaited(
      _animateCameraGuarded(
        CameraUpdate.newCameraPosition(
          const CameraPosition(target: _kDefaultPos, zoom: 14),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // The session can reach `done` on its own (last leg alighted, or the 8h
    // ActivityKit cap). Mirror that back into PlanBloc + PiP so the panel
    // reverts even when the user didn't tap 結束導航.
    return BlocListener<JourneySessionBloc, JourneySessionState>(
      listenWhen: (p, c) => p.phase != c.phase && c.phase == JourneyPhase.done,
      listener: (context, _) => unawaited(_reconcileJourneyDone()),
      child: _buildPlanner(),
    );
  }

  Widget _buildPlanner() {
    return BlocConsumer<PlanBloc, PlanState>(
      listenWhen: (p, c) =>
          _cameraStatusChanged(p, c) || _routeSelectionChanged(p, c),
      // activeStopIndex advances within a leg as the user progresses but does
      // not affect this subtree, so skip those emissions.
      buildWhen: (p, c) =>
          _plannerStructureChanged(p, c) || _savedRouteStatusChanged(p, c),
      listener: _onPlannerChanged,
      builder: _plannerFrame,
    );
  }

  bool _cameraStatusChanged(PlanState p, PlanState c) =>
      p.status != c.status && _hasCameraStatus(c.status);

  bool _hasCameraStatus(PlanStatus status) =>
      status == PlanStatus.success || status == PlanStatus.loading;

  bool _routeSelectionChanged(PlanState p, PlanState c) =>
      p.selectedRouteIndex != c.selectedRouteIndex ||
      p.previewing != c.previewing;

  bool _plannerStructureChanged(PlanState p, PlanState c) =>
      _queryStateChanged(p, c) ||
      _routeSelectionChanged(p, c) ||
      _navigationProgressChanged(p, c);

  bool _queryStateChanged(PlanState p, PlanState c) =>
      p.status != c.status || p.result != c.result || p.error != c.error;

  bool _navigationProgressChanged(PlanState p, PlanState c) =>
      p.activeLegIndex != c.activeLegIndex ||
      p.activeWalkStepIndex != c.activeWalkStepIndex;

  bool _savedRouteStatusChanged(PlanState p, PlanState c) =>
      p.savedRoutes.length != c.savedRoutes.length ||
      p.savedRoutesReady != c.savedRoutesReady ||
      p.savedRoutesLoadError != c.savedRoutesLoadError;

  void _onPlannerChanged(BuildContext context, PlanState state) {
    // Navigation drives its own camera.
    if (state.activeLegIndex != null) return;
    if (state.status == PlanStatus.loading) {
      _fitPending();
      return;
    }
    _framePlannerResult(state);
  }

  void _framePlannerResult(PlanState state) {
    final result = state.result;
    if (result == null || result.routes.isEmpty) return;
    _frameResult(state, result);
  }

  // Preview frames the selected route; results frame every alternative.
  void _frameResult(PlanState state, PlanResult result) {
    if (state.previewing) {
      final route = _activeRoute(state);
      if (route != null) _fitTo(route);
    } else {
      _fitAll(result);
    }
  }

  Widget _plannerFrame(BuildContext context, PlanState state) {
    final navigating = state.activeLegIndex != null;
    final previewing = state.previewing;
    final route = _activeRoute(state);
    final result = state.result;
    final selectedIndex = _selectedIndex(state);
    _layer = _plannerLayer(context, state, result, selectedIndex, route);
    // Back walks the phases outward: navigating → end nav, previewing →
    // results list, results → destination form, form → leave the screen.
    return PopScope(
      canPop: !navigating && !previewing && !_destinationIsOurs,
      onPopInvokedWithResult: (didPop, _) =>
          _plannerBack(didPop, navigating, previewing),
      child: Scaffold(
        resizeToAvoidBottomInset: false,
        body: AnimatedSwitcher(
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : AppMotion.medium,
          switchInCurve: AppMotion.easeOut,
          switchOutCurve: AppMotion.easeOut,
          child: _plannerContent(
            context,
            state,
            navigating,
            previewing,
            route,
            result,
            selectedIndex,
          ),
        ),
      ),
    );
  }

  GoMapLayer _plannerLayer(
    BuildContext context,
    PlanState state,
    PlanResult? result,
    int? selectedIndex,
    PlanRoute? route,
  ) {
    final navigating = state.activeLegIndex != null;
    final colors = Theme.of(context).colorScheme;
    if (!_hasSelectedRoute(result, selectedIndex, route)) {
      return _overlay.pending(
        origin: _origin?.latLng,
        destination: _dest?.latLng,
        colors: colors,
      );
    }
    return _overlay.forPlan(
      result: result!,
      selectedIndex: selectedIndex!,
      colors: colors,
      activeLeg: state.activeLegIndex,
      fix: _navigationFix(navigating),
      puckHeading: _puckHeading,
    );
  }

  bool _hasSelectedRoute(PlanResult? result, int? index, PlanRoute? route) =>
      result != null && index != null && route != null;

  LatLng? _navigationFix(bool navigating) {
    final fix = _lastFix;
    if (!navigating || fix == null) return null;
    return LatLng(fix.latitude, fix.longitude);
  }

  void _plannerBack(bool didPop, bool navigating, bool previewing) {
    if (didPop) return;
    _returnToPlanner(navigating, previewing);
  }

  void _returnToPlanner(bool navigating, bool previewing) {
    if (navigating) {
      _endNav();
    } else if (previewing) {
      _closePreview();
    } else {
      _clearDestination();
    }
  }

  Widget _plannerContent(
    BuildContext context,
    PlanState state,
    bool navigating,
    bool previewing,
    PlanRoute? route,
    PlanResult? result,
    int? selectedIndex,
  ) => _entryVisible(navigating, previewing)
      ? _PlannerEntry(
          key: const ValueKey('entry'),
          origin: _origin,
          originStatus: _originStatus,
          savedRoutes: state.savedRoutes,
          savedRoutesReady: state.savedRoutesReady,
          savedRoutesLoadError: state.savedRoutesLoadError,
          onEditOrigin: () => _editField(origin: true),
          onSwap: _swap,
          onPickDestination: _pickDestination,
          onOpenSaved: _openSaved,
          onToggleSave: _toggleSave,
          onBack: context.popOrHome,
          onEnableLocation: () => unawaited(_initOrigin()),
          onRetrySavedRoutes: () => context.read<PlanBloc>().add(
            const SavedRoutesLoaded(),
          ),
        )
      : KeyedSubtree(
          key: const ValueKey('map'),
          child: _mapPhase(
            context,
            state,
            navigating: navigating,
            previewing: previewing,
            route: route,
            result: result,
            selectedIndex: selectedIndex,
          ),
        );

  bool _entryVisible(bool navigating, bool previewing) =>
      !navigating && !previewing && _dest == null;

  Widget _mapPhase(
    BuildContext context,
    PlanState state, {
    required bool navigating,
    required bool previewing,
    required PlanRoute? route,
    required PlanResult? result,
    required int? selectedIndex,
  }) {
    return Stack(
      children: [
        Positioned.fill(
          child: GoogleMap(
            style: mapStyleOf(context),
            initialCameraPosition: const CameraPosition(
              target: _kDefaultPos,
              zoom: 14,
            ),
            onMapCreated: (c) =>
                _onMapCreated(c, navigating, previewing, route, result),
            // Fires for programmatic moves too, so ignore the app's own
            // animations (via the guard counter) and only treat a real user
            // gesture during navigation as a follow pause.
            onCameraMoveStarted: () => _onCameraMoveStarted(navigating),
            // The default blue dot only in the planner; navigation renders its
            // own directional arrow puck instead.
            myLocationEnabled: !navigating,
            myLocationButtonEnabled: false,
            zoomControlsEnabled: false,
            compassEnabled: false,
            mapToolbarEnabled: false,
            polylines: _layer.polylines,
            markers: _layer.markers,
            // Map shares a Stack with the draggable sheet; without an eager
            // recognizer the map loses the gesture arena, so pan/pinch leak
            // to the sheet instead of moving the map.
            gestureRecognizers: const {
              Factory<OneSequenceGestureRecognizer>(
                EagerGestureRecognizer.new,
              ),
            },
          ),
        ),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: FloatingAppBar(
            automaticallyImplyLeading: false,
            middle: _mapHeader(state, navigating, route),
          ),
        ),
        // Navigating is map-first: the header carries the maneuver and the way
        // out, and nothing else sits over the route.
        if (_showPlannerSheet(navigating, route))
          _sheetSwap(state, route, selectedIndex),
      ],
    );
  }

  bool _showPlannerSheet(bool navigating, PlanRoute? route) =>
      !navigating || route == null;

  Widget _mapHeader(PlanState state, bool navigating, PlanRoute? route) {
    if (navigating && route != null) {
      return _NavHeader(
        route: route,
        activeLeg: state.activeLegIndex!,
        walkStepIndex: state.activeWalkStepIndex,
        onEnd: _endNav,
      );
    }
    return _PlannerHeader(
      origin: _origin,
      dest: _dest,
      onEditOrigin: () => _editField(origin: true),
      onEditDest: () => _editField(origin: false),
      onSwap: _swap,
    );
  }

  void _onMapCreated(
    GoogleMapController controller,
    bool navigating,
    bool previewing,
    PlanRoute? route,
    PlanResult? result,
  ) {
    _map = controller;
    if (navigating) return;
    if (result == null) {
      _fitPending();
      return;
    }
    _frameCreatedMap(previewing, route, result);
  }

  void _frameCreatedMap(bool previewing, PlanRoute? route, PlanResult result) {
    if (previewing && route != null) {
      _fitTo(route);
    } else {
      _fitAll(result);
    }
  }

  void _onCameraMoveStarted(bool navigating) {
    if (!navigating || _cameraMoveProgrammatic()) return;
    if (!_followPaused) setState(() => _followPaused = true);
  }

  bool _cameraMoveProgrammatic() =>
      _programmaticMoves > 0 ||
      DateTime.now().difference(_lastProgrammaticMove) <
          _kProgrammaticMoveGrace;

  Duration _swapDuration(bool reduced, Duration duration) =>
      reduced ? Duration.zero : duration;

  Widget _sheetSwap(PlanState state, PlanRoute? route, int? selectedIndex) {
    final reduce = MediaQuery.disableAnimationsOf(context);
    final showPreview = state.previewing && route != null;
    final child = showPreview
        ? _previewSheetFor(state, route, selectedIndex)
        : _plannerSheetFor(state);
    return AnimatedSwitcher(
      duration: _swapDuration(reduce, AppMotion.medium),
      reverseDuration: _swapDuration(reduce, AppMotion.micro),
      switchInCurve: AppMotion.easeOut,
      switchOutCurve: AppMotion.easeOut,
      transitionBuilder: (child, anim) => FadeTransition(
        opacity: anim,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.03),
            end: Offset.zero,
          ).animate(anim),
          child: child,
        ),
      ),
      child: child,
    );
  }

  bool _isFastest(PlanState state, int? index) =>
      _hasAlternatives(state) && (index ?? 0) == 0;

  bool _hasAlternatives(PlanState state) =>
      (state.result?.routes.length ?? 0) > 1;

  Widget _previewSheetFor(
    PlanState state,
    PlanRoute route,
    int? selectedIndex,
  ) => _PreviewSheet(
    key: const ValueKey('preview'),
    controller: _previewSheet,
    // Carry the planner sheet's height into the preview swap.
    initialOffset: carriedSheetOffset(
      _sheet,
      min: AppSheetSnap.peekFrac,
      max: AppSheetSnap.full,
      fallback: AppSheetSnap.halfFrac,
    ),
    route: route,
    isFastest: _isFastest(state, selectedIndex),
    isSaved: state.savedKeys.contains(route.savedKey),
    origin: _origin?.name,
    dest: _dest?.name,
    onBack: _closePreview,
    onStartNavigation: () => _startFromPreview(route, selectedIndex ?? 0),
    onToggleSave: () => _toggleSave(route),
  );

  Widget _plannerSheetFor(PlanState state) => _PlannerSheet(
    key: const ValueKey('planner'),
    controller: _sheet,
    // Carry the preview sheet's height back into the planner swap.
    initialOffset: carriedSheetOffset(
      _previewSheet,
      min: AppSheetSnap.peekFrac,
      max: AppSheetSnap.full,
      fallback: AppSheetSnap.halfFrac,
    ),
    state: state,
    hasDestination: _dest != null,
    timeMode: _timeMode,
    timeAt: _timeAt,
    routeCount: _options.top,
    lastRoute: _lastRouteForTrip(state.savedRoutes),
    straightLineMeters: _straightLineMeters(),
    onSelect: _previewRoute,
    onRetry: _retry,
    onCancel: _cancelPlan,
    onAdjustOptions: _adjustOptions,
    onAdjustTime: _adjustTime,
    onPage: _page,
    onToggleSave: _toggleSave,
  );

  int? _selectedIndex(PlanState state) {
    final routes = state.result?.routes;
    if (routes == null || routes.isEmpty) return null;
    final i = state.selectedRouteIndex ?? 0;
    return _boundedRouteIndex(i, routes.length);
  }

  int _boundedRouteIndex(int index, int count) =>
      index >= 0 && index < count ? index : 0;

  PlanRoute? _activeRoute(PlanState state) {
    final i = _selectedIndex(state);
    return i == null ? null : state.result!.routes[i];
  }
}
