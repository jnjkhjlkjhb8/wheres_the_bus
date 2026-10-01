import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widget_previews.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:smooth_sheets/smooth_sheets.dart';
import 'package:wheres_the_bus/app/router/app_routes.dart';
import 'package:wheres_the_bus/app/theme/app_text_styles.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/core/haptics/haptic_service.dart';
import 'package:wheres_the_bus/core/location/location_service.dart';
import 'package:wheres_the_bus/core/location/nearest_within.dart';
import 'package:wheres_the_bus/data/models/favorite.dart';
import 'package:wheres_the_bus/data/models/journey_info.dart';
import 'package:wheres_the_bus/data/models/metro_map_models.dart';
import 'package:wheres_the_bus/data/models/metro_topology.dart';
import 'package:wheres_the_bus/data/repositories/near_repository.dart';
import 'package:wheres_the_bus/features/favorites/bloc/favorites_bloc.dart';
import 'package:wheres_the_bus/features/metro/bloc/metro_bloc.dart';
import 'package:wheres_the_bus/features/metro/bloc/metro_event.dart';
import 'package:wheres_the_bus/features/metro/bloc/metro_state.dart';
import 'package:wheres_the_bus/features/metro/bloc/mrt_track_bloc.dart';
import 'package:wheres_the_bus/features/metro/bloc/mrt_track_event.dart';
import 'package:wheres_the_bus/features/metro/bloc/mrt_track_state.dart';
import 'package:wheres_the_bus/features/metro/data/metro_line_names.dart';
import 'package:wheres_the_bus/features/metro/data/mrt_car_binding.dart';
import 'package:wheres_the_bus/features/metro/view/metro_station_detail_view.dart';
import 'package:wheres_the_bus/features/metro/widgets/metro_svg_map.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/motion/app_motion.dart';
import 'package:wheres_the_bus/shared/motion/pressable.dart';
import 'package:wheres_the_bus/shared/widgets/alight_track/alight_confirm_bar.dart';
import 'package:wheres_the_bus/shared/widgets/alight_track/alight_pick_capsule.dart';
import 'package:wheres_the_bus/shared/widgets/app_bars.dart';
import 'package:wheres_the_bus/shared/widgets/app_sliding_segment.dart';
import 'package:wheres_the_bus/shared/widgets/app_snackbar.dart';
import 'package:wheres_the_bus/shared/widgets/bottom_sheet_shell.dart';
import 'package:wheres_the_bus/shared/widgets/error_state_view.dart';
import 'package:wheres_the_bus/shared/widgets/transport_icon.dart';

part '../widgets/metro_placeholder_widgets.dart';
part '../widgets/metro_system_widgets.dart';

final RegExp _digits = RegExp(r'\d+');

String _lineCode(String id) => id.split('_').first.replaceAll(_digits, '');

String _lineName(AppI18n i18n, String id) =>
    metroLineNames(i18n)[_lineCode(id)] ?? _lineCode(id);

TransportType _getTransportType(String line) {
  switch (line) {
    case 'BL':
      return TransportType.mrtBL;
    case 'R':
      return TransportType.mrtR;
    case 'G':
      return TransportType.mrtG;
    case 'BR':
      return TransportType.mrtBR;
    case 'O':
      return TransportType.mrtO;
    default:
      return TransportType.mrtBL;
  }
}

@Preview(name: 'MetroScreen — full', group: 'Metro', size: Size(390, 844))
Widget metroScreenPreview() => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: AppTheme.light,
  home: const MetroScreen(),
);

@Preview(
  name: 'MetroScreen — full (dark)',
  group: 'Metro',
  brightness: Brightness.dark,
  size: Size(390, 844),
)
Widget metroScreenDarkPreview() => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: AppTheme.dark,
  home: const MetroScreen(),
);

@Preview(
  name: 'MetroScreen — station detail',
  group: 'Metro',
  size: Size(390, 720),
)
Widget metroDetailPreview() {
  final station = metroMapStations.firstWhere(
    (s) => s.id.contains('_'),
    orElse: () => metroMapStations.first,
  );
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.light,
    home: Scaffold(
      backgroundColor: AppTheme.surfaceLight,
      body: SafeArea(
        child: MetroStationDetailView(
          system: 'TRTC',
          stationId: station.id,
          name: station.name,
          onClose: () {},
        ),
      ),
    ),
  );
}

class MetroScreen extends StatefulWidget {
  const MetroScreen({super.key, this.stationId, this.mode = MetroMapMode.time});

  final String? stationId;

  /// What the map labels stations with, from `?mode=`.
  final MetroMapMode mode;

  @override
  State<MetroScreen> createState() => _MetroScreenState();
}

/// How close the rider must be for the bare map to open on a station for them.
/// Metro stations are large and their exits spread out, so this is generous
/// enough to fire from the far end of a concourse.
const _kAutoFocusRadiusMeters = 300;

class _MetroScreenState extends State<MetroScreen> {
  MetroMapStation? _selected;
  MetroMapStation? _prevSelected;

  /// Set while [_autoFocusNearest] drives the next selection, so it lands
  /// without the tap haptic — the rider did not tap anything.
  bool _autoSelecting = false;
  late MetroMapMode _mode = widget.mode;
  final _metroBloc = MetroBloc();
  final _sheetController = SheetController();

  @override
  void initState() {
    super.initState();
    final station = _stationFor(widget.stationId);
    if (station == null) {
      unawaited(_autoFocusNearest());
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _selectStation(station);
    });
  }

  Future<void> _autoFocusNearest() async {
    try {
      final fix = await LocationService.instance.lastKnownPosition();
      if (!mounted ||
          fix == null ||
          !usableAutoFocusFix(
            fix,
            maxAccuracyMeters: _kAutoFocusRadiusMeters.toDouble(),
            now: DateTime.now().toUtc(),
          )) {
        return;
      }
      final stations = await NearRepository.instance
          .nearOnce(fix.latitude, fix.longitude, _kAutoFocusRadiusMeters)
          .first;
      // The rider may have picked a station themselves while the query was in
      // flight; auto-focus is a head start, never a correction.
      if (!mounted || _selected != null || widget.stationId != null) return;
      final near = nearestWithin(
        stations.where((s) => s.type == NearStationType.mrt),
        lat: fix.latitude,
        lon: fix.longitude,
        radiusMeters: _kAutoFocusRadiusMeters.toDouble(),
        latOf: (s) => s.lat,
        lonOf: (s) => s.lon,
      );
      if (near == null) return;
      final id = metroStationIdForName(near.stationName);
      if (id == null || _stationFor(id) == null) return;
      _autoSelecting = true;
      _goToStation(_stationFor(id)!);
    } on Object {
      // Manual station selection remains available if location lookup fails.
    }
  }

  @override
  void didUpdateWidget(MetroScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.mode != _mode) setState(() => _mode = widget.mode);
    if (widget.stationId == _selected?.id) return;
    final station = _stationFor(widget.stationId);
    if (station == null) {
      _clearSelection();
    } else {
      _selectStation(station);
    }
  }

  static MetroMapStation? _stationFor(String? id) {
    if (id == null || id.isEmpty) return null;
    for (final station in metroMapStations) {
      if (station.id == id) return station;
    }
    return null;
  }

  /// Writes a selection to the location; the sheet and the labels follow in
  /// [didUpdateWidget]. `replace` rather than `push`: picking another station
  /// is the same page showing something else, not a place to come back to.
  void _goToStation(MetroMapStation station) =>
      context.replace(AppRoutes.metroStation(station.id, mode: _mode));

  void _goToMode(MetroMapMode mode) => context.replace(
    _selected == null
        ? AppRoutes.metroLocation(mode: mode)
        : AppRoutes.metroStation(_selected!.id, mode: mode),
  );

  @override
  void dispose() {
    unawaited(_metroBloc.close());
    _sheetController.dispose();
    super.dispose();
  }

  /// The stations the boarded train still calls at, or null when no pick is
  /// open. Null is what puts the map back in its normal mode.
  Set<String>? _pickAheadIds(BuildContext context) {
    final arrival = context.watch<MrtTrackBloc>().state.pickArrival;
    if (arrival == null) return null;
    return MetroTopology.aheadStations(
      line: arrival.line,
      boardCode: arrival.stationId,
      terminalCode: arrival.destinationStationId,
    ).map((stop) => stop.id).toSet();
  }

  /// A tap on the map means "select this station" normally, and "this is where
  /// I get off" while a pick is open.
  void _onMapStationTap(MetroMapStation station) {
    final track = context.read<MrtTrackBloc>();
    if (track.state.picking) {
      track.add(MrtAlightTargetPicked(station.id));
      return;
    }
    _goToStation(station);
  }

  /// Closing the detail is a location change too, so the URL never claims a
  /// station the sheet has stopped showing.
  void _dismiss() => context.replace(AppRoutes.metroLocation(mode: _mode));

  void _clearSelection() {
    _metroBloc.add(const MetroStationDismissed());
    setState(() {
      _prevSelected = null;
      _selected = null;
    });
  }

  void _selectStation(MetroMapStation station) {
    if (_autoSelecting) {
      _autoSelecting = false;
    } else {
      unawaited(HapticService.instance.lightTap());
    }
    setState(() {
      _prevSelected = _selected;
      _selected = station;
    });
    _metroBloc.add(MetroStationTapped(stationId: station.id));
    // `half`: enough room to read the station's detail card without a drag,
    // while the map above it stays visible. The map itself never moves, so a
    // station tapped while zoomed in stays exactly under the finger.
    unawaited(
      _sheetController.animateToDetent(
        AppSheetSnap.half,
        reduced: AppMotion.reduced(context),
      ),
    );
  }

  Map<String, String> _buildLabels(
    List<MetroMapStation> all,
    Map<String, JourneyInfo>? matrix,
  ) {
    if (_selected == null || matrix == null) return const {};
    return {
      for (final s in all)
        if (s.id != _selected!.id)
          if (_journeyFor(matrix, s.id) case final info?)
            s.id: _mode == MetroMapMode.time
                ? (info.travelTimeMin > 0 ? '${info.travelTimeMin}' : '—')
                : '${info.fareNt}',
    };
  }

  /// Interchange ids combine both line codes (e.g. `'BL15_BR10'`); the matrix
  /// is keyed by single TDX codes, so match on whichever component is present.
  JourneyInfo? _journeyFor(Map<String, JourneyInfo> matrix, String id) {
    for (final code in id.split('_')) {
      if (matrix[code] case final info?) return info;
    }
    return null;
  }

  Widget _buildBottomSheetWidget(BuildContext context, ColorScheme cs) {
    return AppSheet(
      controller: _sheetController,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SheetDragHandle(),
          const SizedBox(height: AppTheme.space12),
          Flexible(
            child: BlocBuilder<MetroBloc, MetroState>(
              builder: (context, state) => AnimatedSwitcher(
                duration: AppMotion.short,
                switchInCurve: AppMotion.easeOut,
                switchOutCurve: AppMotion.easeOut,
                transitionBuilder: (child, animation) => FadeTransition(
                  opacity: animation,
                  child: SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(0, 0.04),
                      end: Offset.zero,
                    ).animate(animation),
                    child: child,
                  ),
                ),
                layoutBuilder: (currentChild, previousChildren) => Stack(
                  alignment: Alignment.topCenter,
                  children: [
                    for (final child in previousChildren)
                      Positioned.fill(child: child),
                    ?currentChild,
                  ],
                ),
                child: state.error != null
                    ? ErrorStateView(
                        key: const ValueKey('error'),
                        error: state.error!,
                        onRetry: _selected == null
                            ? null
                            : () => _metroBloc.add(
                                MetroStationTapped(stationId: _selected!.id),
                              ),
                      )
                    : _selected != null
                    ? MetroStationDetailView(
                        key: ValueKey('detail:${_selected!.id}'),
                        system: 'TRTC',
                        stationId: _selected!.id,
                        name: _selected!.name,
                        onClose: _dismiss,
                      )
                    : _MetroPlaceholderSheet(
                        key: const ValueKey('placeholder'),
                        onStationSelect: _goToStation,
                        sheetController: _sheetController,
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return PopScope(
      // A station selected: back closes the sheet instead of leaving the
      // page, since the sheet and the bare map share one Navigator entry.
      canPop: _selected == null,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _dismiss();
      },
      child: BlocProvider.value(
        value: _metroBloc,
        child: Scaffold(
          backgroundColor: cs.brightness == Brightness.dark
              ? const Color(0xFF0C0C0C)
              : Colors.white,
          body: Stack(
            fit: StackFit.expand,
            children: [
              BlocBuilder<MetroBloc, MetroState>(
                // The map only reads journeyMatrix (via _buildLabels below);
                // activeStationId/error changes elsewhere in MetroState
                // shouldn't force a full SVG map + ~120 label rebuild.
                buildWhen: (previous, current) =>
                    previous.journeyMatrix != current.journeyMatrix,
                builder: (context, state) => MetroSvgMap(
                  selectedStationId: _selected?.id,
                  onStationTap: _onMapStationTap,
                  pickAheadIds: _pickAheadIds(context),
                  pickBoardId: context
                      .watch<MrtTrackBloc>()
                      .state
                      .pickArrival
                      ?.stationId,
                  pickedStationId: context
                      .watch<MrtTrackBloc>()
                      .state
                      .pickTargetStationId,
                  stationLabels: _buildLabels(
                    metroMapStations,
                    state.journeyMatrix,
                  ),
                  animate: _prevSelected == null && _selected != null,
                ),
              ),
              Align(
                alignment: Alignment.topCenter,
                child: FloatingAppBar(
                  leading: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AppBarBackButton(floating: true),
                      SizedBox(width: AppBarMetrics.gap),
                      _SystemPill(),
                    ],
                  ),
                  trailing: Flexible(
                    child: AnimatedSwitcher(
                      duration: AppMotion.short,
                      switchInCurve: AppMotion.easeOut,
                      switchOutCurve: AppMotion.easeOut,
                      transitionBuilder: (child, animation) => FadeTransition(
                        opacity: animation,
                        child: ScaleTransition(
                          scale: Tween<double>(
                            begin: 0.9,
                            end: 1,
                          ).animate(animation),
                          child: child,
                        ),
                      ),
                      child: _selected != null
                          ? _MapModeChip(
                              key: const ValueKey('map-mode-chip'),
                              mode: _mode,
                              onChanged: _goToMode,
                            )
                          : const SizedBox.shrink(),
                    ),
                  ),
                ),
              ),
              if (!context.watch<MrtTrackBloc>().state.picking)
                _buildBottomSheetWidget(context, cs),
              if (context.watch<MrtTrackBloc>().state.picking)
                Positioned(
                  top: MediaQuery.paddingOf(context).top + 60,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: AlightPickCapsule(
                      onCancel: () => context.read<MrtTrackBloc>().add(
                        const MrtAlightPickCancelled(),
                      ),
                    ),
                  ),
                ),
              const Align(
                alignment: Alignment.bottomCenter,
                child: _MetroAlightDock(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MetroAlightDock extends StatefulWidget {
  const _MetroAlightDock();

  @override
  State<_MetroAlightDock> createState() => _MetroAlightDockState();
}

class _MetroAlightDockState extends State<_MetroAlightDock> {
  final _carController = TextEditingController();

  @override
  void dispose() {
    _carController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<MrtTrackBloc, MrtTrackBlocState>(
      builder: (context, state) {
        final arrival = state.pickArrival;
        final targetId = state.pickTargetStationId;
        if (arrival == null || targetId == null) {
          return const SizedBox.shrink();
        }
        final ahead = MetroTopology.aheadStations(
          line: arrival.line,
          boardCode: arrival.stationId,
          terminalCode: arrival.destinationStationId,
        );
        final target = ahead.where((s) => s.id == targetId).firstOrNull;
        if (target == null) return const SizedBox.shrink();

        final autoCarId = deriveCarIdFromCn1(arrival.cn1);
        final carId = arrival.cn1.isNotEmpty
            ? autoCarId
            : _carController.text.trim();

        return AlightConfirmBar(
          targetName: target.name,
          lead: state.pickLead,
          onLeadChanged: (v) =>
              context.read<MrtTrackBloc>().add(MrtAlightLeadChanged(v)),
          onRepick: () => context.read<MrtTrackBloc>().add(
            const MrtAlightTargetCleared(),
          ),
          onCancel: () => context.read<MrtTrackBloc>().add(
            const MrtAlightPickCancelled(),
          ),
          canStart: carId.isNotEmpty,
          busy: state.creating,
          errorText: state.createError == MrtTrackCreateError.none
              ? null
              : _errorText(AppI18n.of(context), state.createError),
          binding: arrival.cn1.isNotEmpty
              ? AlightBindingChip(
                  label: AppI18n.of(context).metroCarChip(autoCarId),
                )
              : _CarNumberField(
                  controller: _carController,
                  // The CTA is gated on a car number being present, so the
                  // field has to force a rebuild as it is typed.
                  onChanged: (_) => setState(() {}),
                ),
          onStart: () => context.read<MrtTrackBloc>().add(
            MrtTrackRequested(
              carId: carId,
              boardStationId: arrival.stationId,
              destStationId: arrival.destinationStationId,
              targetStationId: target.id,
              leadStops: state.pickLead,
              // The reminder can be armed from the platform while the train is
              // still several stations out; these let the session watch the
              // arrival board until it pulls in.
              system: arrival.system,
              trainNumber: arrival.trainNumber,
              boardEtaSeconds: arrival.estimateSeconds,
            ),
          ),
        );
      },
    );
  }

  static String _errorText(AppI18n i18n, MrtTrackCreateError error) =>
      switch (error) {
        MrtTrackCreateError.notReachable => i18n.mrtAlightNotReachable,
        MrtTrackCreateError.notFound => i18n.mrtAlightNotFound,
        MrtTrackCreateError.generic => i18n.mrtAlightGenericError,
        MrtTrackCreateError.none => '',
      };
}

/// Manual carriage entry, for a train whose congestion feed came unpaired.
class _CarNumberField extends StatelessWidget {
  const _CarNumberField({required this.controller, required this.onChanged});

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return TextField(
      controller: controller,
      onChanged: onChanged,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      style: AppTextStyles.memo.copyWith(fontSize: 16),
      decoration: InputDecoration(
        isDense: true,
        labelText: AppI18n.of(context).mrtAlightCarNumberLabel,
        hintText: AppI18n.of(context).mrtAlightCarNumberHint,
        hintStyle: AppTextStyles.memo.copyWith(
          fontSize: 16,
          color: cs.onSurfaceVariant,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusButton),
        ),
      ),
    );
  }
}
