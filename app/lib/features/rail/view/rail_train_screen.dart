import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:wheres_the_bus/app/theme/app_text_styles.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/core/errors/app_error.dart';
import 'package:wheres_the_bus/core/haptics/haptic_service.dart';
import 'package:wheres_the_bus/data/models/fare_type.dart';
import 'package:wheres_the_bus/data/models/rail_fare_quote.dart';
import 'package:wheres_the_bus/data/tracking/journey_models.dart';
import 'package:wheres_the_bus/data/tracking/journey_session_bloc.dart';
import 'package:wheres_the_bus/data/tracking/journey_session_event.dart';
import 'package:wheres_the_bus/data/tracking/journey_session_state.dart';
import 'package:wheres_the_bus/data/tracking/tracking_session.dart';
import 'package:wheres_the_bus/features/rail/bloc/rail_train_bloc.dart';
import 'package:wheres_the_bus/features/rail/bloc/rail_train_event.dart';
import 'package:wheres_the_bus/features/rail/bloc/rail_train_state.dart';
import 'package:wheres_the_bus/features/rail/booking_launch.dart';
import 'package:wheres_the_bus/features/rail/rail_timetable_derivation.dart';
import 'package:wheres_the_bus/features/rail/widgets/rail_booking_sheet.dart';
import 'package:wheres_the_bus/features/rail/widgets/rail_service_marks.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/motion/pressable.dart';
import 'package:wheres_the_bus/shared/widgets/alight_track/alight_confirm_bar.dart';
import 'package:wheres_the_bus/shared/widgets/alight_track/alight_pick_capsule.dart';
import 'package:wheres_the_bus/shared/widgets/alight_track/alight_track_bell.dart';
import 'package:wheres_the_bus/shared/widgets/app_bars.dart';
import 'package:wheres_the_bus/shared/widgets/app_card.dart';
import 'package:wheres_the_bus/shared/widgets/app_spinner.dart';
import 'package:wheres_the_bus/shared/widgets/bookmark_button.dart';
import 'package:wheres_the_bus/shared/widgets/error_state_view.dart';
import 'package:wheres_the_bus/shared/widgets/fare_preference.dart';
import 'package:wheres_the_bus/shared/widgets/freshness_stamp.dart';
import 'package:wheres_the_bus/shared/widgets/route_tab_bar.dart';
import 'package:wheres_the_bus/shared/widgets/train_type_chip.dart';
import 'package:wheres_the_bus/shared/widgets/transit_timeline.dart';

part 'rail_train_info_tab.dart';
part 'rail_train_timetable_tab.dart';

List<RailStopSchedule> railTrackSchedule(
  List<RailTrainStop> stops,
  String serviceDate, {
  required String board,
  required String alight,
}) {
  final b = stops.indexWhere((s) => sameStation(s.name, board));
  final a = stops.indexWhere((s) => sameStation(s.name, alight));
  if (b < 0 || a <= b) return const [];
  final out = <RailStopSchedule>[];
  for (var i = b; i <= a; i++) {
    final s = stops[i];
    final raw = s.arrive.isNotEmpty ? s.arrive : s.depart;
    final t = DateTime.tryParse('$serviceDate ${hhmm(raw)}');
    if (t == null) return const [];
    out.add(RailStopSchedule(name: s.name, scheduledArrival: t));
  }
  return out;
}

// Built per call rather than held in a const map: the names follow the
// rider's language.
Map<int, String> _weekdayLabels(AppI18n i18n) => {
  DateTime.monday: i18n.weekdayMon,
  DateTime.tuesday: i18n.weekdayTue,
  DateTime.wednesday: i18n.weekdayWed,
  DateTime.thursday: i18n.weekdayThu,
  DateTime.friday: i18n.weekdayFri,
  DateTime.saturday: i18n.weekdaySat,
  DateTime.sunday: i18n.weekdaySun,
};

String _formatDateDisplay(AppI18n i18n, String isoDate) {
  final date = DateTime.tryParse(isoDate);
  if (date == null) return isoDate.replaceAll('-', '/');
  final mm = date.month.toString().padLeft(2, '0');
  final dd = date.day.toString().padLeft(2, '0');
  return '$mm/$dd (${_weekdayLabels(i18n)[date.weekday]})';
}

class RailTrainExtra {
  const RailTrainExtra({
    this.typeLabel,
    this.userOrigin,
    this.userDest,
    this.delayMinutes = 0,
    this.marks = const [],
    this.remark = '',
  });

  /// Train type as the caller displayed it (e.g. `自強`). Null falls back to
  /// the system's own label.
  final String? typeLabel;
  final String? userOrigin;
  final String? userDest;
  final int delayMinutes;
  final List<RailServiceMark> marks;
  final String remark;
}

class RailTrainScreen extends StatefulWidget {
  const RailTrainScreen({
    required this.type,
    required this.trainNo,
    required this.date,
    this.userOrigin,
    this.userDest,
    this.delayMinutes = 0,
    this.marks = const [],
    this.remark = '',
    super.key,
  });

  final String type;
  final String trainNo;

  /// Service date in `yyyy-MM-dd`.
  final String date;

  final String? userOrigin;
  final String? userDest;

  /// Live delay in minutes for this train, when the caller had it (the O/D
  /// result list subscribes to delays; this screen does not). Folded into the
  /// 追蹤 countdown so it reflects the actual 誤點 rather than the timetable.
  final int delayMinutes;

  final List<RailServiceMark> marks;
  final String remark;

  @override
  State<RailTrainScreen> createState() => _RailTrainScreenState();
}

enum _AlightMode { idle, picking, confirm, manage }

class _RailTrainScreenState extends State<RailTrainScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  late final RailTrainBloc _bloc;

  _AlightMode _alightMode = _AlightMode.idle;

  /// Station name of the chosen 下車站, or null before one is settled.
  String? _alightTarget;

  /// Whether [_alightTarget] came from the rider's own O/D search rather than
  /// from a tap on the timetable.
  bool _alightFromSearch = false;

  /// 提前站數, two on every network: one stop is often under a minute's warning
  /// on a fast train, three is most of a short ride.
  int _alightLead = 0;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _bloc = RailTrainBloc(
      type: widget.type,
      trainNo: widget.trainNo,
      date: widget.date,
      userOrigin: widget.userOrigin,
      userDest: widget.userDest,
    )..add(const RailTrainStarted());
  }

  @override
  void dispose() {
    _tabController.dispose();
    unawaited(_bloc.close());
    super.dispose();
  }

  // trainNo lives in identity.routeKey and the service date in
  // identity.direction (trackOnly rail legs carry no real O/D keys), so both
  // must match to recognise this train as the one being tracked.
  bool _isTrackingThisTrain(JourneySessionState s) => isTrackingTrain(
    s,
    trainNo: widget.trainNo,
    serviceDate: widget.date,
  );

  /// The boarding stop: the one the rider actually searched from, falling back
  /// to the train's origin when this screen was opened by train number alone.
  RailTrainStop? _boardStop(List<RailTrainStop> stops) {
    if (stops.isEmpty) return null;
    final origin = widget.userOrigin;
    if (origin == null) return stops.first;
    for (final s in stops) {
      if (sameStation(s.name, origin)) return s;
    }
    return stops.first;
  }

  /// Stops the train still calls at after boarding — the 下車站 candidates.
  List<RailTrainStop> _aheadStops(List<RailTrainStop> stops) {
    final board = _boardStop(stops);
    if (board == null) return const [];
    final at = stops.indexOf(board);
    return at < 0 ? const [] : stops.sublist(at + 1);
  }

  JourneyLeg? _buildLeg(
    AppI18n i18n,
    List<RailTrainStop> stops,
    RailTrainStop alight,
    int delayMinutes,
    String trainLabel,
  ) {
    final board = _boardStop(stops);
    if (board == null) return null;
    final departRaw = board.depart.isNotEmpty ? board.depart : board.arrive;
    final arriveRaw = alight.arrive.isNotEmpty ? alight.arrive : alight.depart;
    final departAt = DateTime.tryParse('${widget.date} ${hhmm(departRaw)}');
    return railTrackingLeg(
      i18n: i18n,
      isThsr: widget.type == '高鐵',
      trainNo: widget.trainNo,
      trainLabel: trainLabel,
      serviceDate: widget.date,
      boardName: board.name,
      alightName: alight.name,
      scheduledDeparture: departAt,
      scheduledArrival: DateTime.tryParse('${widget.date} ${hhmm(arriveRaw)}'),
      delayMinutes: delayMinutes,
      // The whole board→alight segment travels on the leg so the live tracker
      // can keep deriving 還剩 N 站 / progress after this screen is disposed.
      // Delay is NOT folded in here — the tracker applies live 誤點 itself.
      railSchedule: railTrackSchedule(
        stops,
        widget.date,
        board: board.name,
        alight: alight.name,
      ),
    );
  }

  /// Opens the flow from the bell. The O/D search already answered "which
  /// station", so the usual landing is the confirm bar, not a picker.
  void _enterAlight(List<RailTrainStop> stops) {
    final ahead = _aheadStops(stops);
    if (ahead.isEmpty) return;
    final dest = widget.userDest;
    final known = dest == null
        ? null
        : ahead.where((s) => sameStation(s.name, dest)).firstOrNull;
    setState(() {
      _alightTarget = known?.name;
      _alightFromSearch = known != null;
      _alightLead = 0;
      _alightMode = known == null ? _AlightMode.picking : _AlightMode.confirm;
    });
  }

  void _pickAlight(String stationName) {
    unawaited(HapticService.instance.selectionClick());
    setState(() {
      _alightTarget = stationName;
      _alightFromSearch = false;
      _alightMode = _AlightMode.confirm;
    });
  }

  void _cancelAlight() {
    setState(() {
      _alightMode = _AlightMode.idle;
      _alightTarget = null;
      _alightFromSearch = false;
    });
  }

  void _startAlight(List<RailTrainStop> stops, String trainLabel, int delay) {
    final target = _alightTarget;
    if (target == null) return;
    final alight = _aheadStops(
      stops,
    ).where((s) => sameStation(s.name, target)).firstOrNull;
    if (alight == null) return;
    final leg = _buildLeg(
      AppI18n.of(context),
      stops,
      alight,
      delay,
      trainLabel,
    );
    if (leg == null) return;
    context.read<JourneySessionBloc>().add(
      JourneyStarted(trackOnly: true, legs: [leg], leadStops: _alightLead),
    );
    setState(() => _alightMode = _AlightMode.idle);
  }

  @override
  Widget build(BuildContext context) {
    final trainLabel = TrainTypeChip.canonicalLabel(
      AppI18n.of(context),
      widget.type,
    );

    return BlocProvider.value(
      value: _bloc,
      child: Scaffold(
        appBar: DetailAppBar(
          title: '$trainLabel ${widget.trainNo}',
          subtitle: _formatDateDisplay(AppI18n.of(context), widget.date),
          actions: [
            BlocBuilder<RailTrainBloc, RailTrainState>(
              builder: (context, state) {
                // Nothing to set a reminder on until the stop list has landed.
                if (_aheadStops(state.stops).isEmpty) {
                  return const SizedBox.shrink();
                }
                return BlocSelector<
                  JourneySessionBloc,
                  JourneySessionState,
                  bool
                >(
                  selector: _isTrackingThisTrain,
                  builder: (context, armed) => AlightTrackBell(
                    active: armed,
                    semanticLabel: armed
                        ? AppI18n.of(
                            context,
                          ).railTrackingSemantics(trainLabel, widget.trainNo)
                        : AppI18n.of(
                            context,
                          ).railTrackSemantics(trainLabel, widget.trainNo),
                    onTap: () {
                      // Armed opens the manage card rather than cancelling on
                      // the spot; idle opens the flow; mid-flow it backs out.
                      if (armed) {
                        setState(() => _alightMode = _AlightMode.manage);
                      } else if (_alightMode == _AlightMode.idle) {
                        _enterAlight(state.stops);
                      } else {
                        _cancelAlight();
                      }
                    },
                  ),
                );
              },
            ),
            BookmarkButton(
              routeType: widget.type,
              routeKey: widget.trainNo,
              routeLabel: '${widget.type} ${widget.trainNo}',
            ),
          ],
        ),
        bottomNavigationBar: BlocBuilder<RailTrainBloc, RailTrainState>(
          builder: (context, state) {
            if (state.status != RailTrainStatus.loaded) {
              return const SizedBox.shrink();
            }
            // While the reminder is being set the bottom edge belongs to it:
            // two bars stacked is one bar too many, and 訂購 is not the task
            // the rider is in the middle of.
            final target = _alightTarget;
            if (_alightMode == _AlightMode.confirm && target != null) {
              return AlightConfirmBar(
                targetName: target,
                fromSearch: _alightFromSearch,
                lead: _alightLead,
                onLeadChanged: (v) => setState(() => _alightLead = v),
                onRepick: () =>
                    setState(() => _alightMode = _AlightMode.picking),
                onCancel: _cancelAlight,
                onStart: () => _startAlight(
                  state.stops,
                  trainLabel,
                  state.liveDelayMinutes ?? widget.delayMinutes,
                ),
              );
            }
            if (_alightMode == _AlightMode.manage) {
              final leg = context.read<JourneySessionBloc>().state.currentLeg;
              return AlightManageBar(
                targetName: leg?.alightStop ?? target ?? '',
                lead: _alightLead,
                onClose: () => setState(() => _alightMode = _AlightMode.idle),
                onCancel: () {
                  context.read<JourneySessionBloc>().add(
                    const JourneyCancelled(userInitiated: true),
                  );
                  _cancelAlight();
                },
              );
            }
            // Scoped to the user's own boarding stop when known, so a THSR
            // hand-off pre-fills the departure they searched rather than the
            // train's first stop hours up the line.
            final boarding = widget.userOrigin == null
                ? state.stops.firstOrNull
                : state.stops
                      .where((s) => sameStation(s.name, widget.userOrigin!))
                      .firstOrNull;
            return _BookingBar(
              isThsr: widget.type == '高鐵',
              trainNo: widget.trainNo,
              date: widget.date,
              origin: widget.userOrigin ?? state.stops.firstOrNull?.name ?? '',
              destination:
                  widget.userDest ?? state.stops.lastOrNull?.name ?? '',
              departTime: hhmm(
                (boarding?.depart.isNotEmpty ?? false)
                    ? boarding!.depart
                    : (boarding?.arrive ?? ''),
              ),
              // The user's own segment is what the timetable quoted, so it is
              // the number to repeat here; the full run is the fallback.
              fareQuote: state.userFare ?? state.fullFare,
              trainType: widget.type,
              // Carried from the timetable list; a screen opened by train
              // number alone has no marks, so 兩鐵 stays hidden rather than
              // being offered on a train that may not take bicycles.
              hasBikeService: widget.marks.contains(RailServiceMark.bike),
            );
          },
        ),
        body: BlocBuilder<RailTrainBloc, RailTrainState>(
          builder: (context, state) {
            switch (state.status) {
              case RailTrainStatus.loading:
                return const Center(child: AppSpinner());
              case RailTrainStatus.error:
                return ErrorStateView(
                  error: state.error ?? const UnknownError(),
                  onRetry: () => _bloc.add(const RailTrainStarted()),
                );
              case RailTrainStatus.empty:
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppTheme.space32,
                    ),
                    child: Text(
                      AppI18n.of(context).railTrainNotFound(
                        trainLabel,
                        widget.trainNo,
                        _formatDateDisplay(AppI18n.of(context), widget.date),
                      ),
                      textAlign: TextAlign.center,
                      style: AppTextStyles.bodyRegular.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                );
              case RailTrainStatus.loaded:
                return AlightPickCapsuleHost(
                  picking: _alightMode == _AlightMode.picking,
                  onCancel: _cancelAlight,
                  child: Column(
                    children: [
                      RouteTabBar(
                        controller: _tabController,
                        tabs: [
                          AppI18n.of(context).railTabTimetable,
                          AppI18n.of(context).railTabDetails,
                        ],
                      ),
                      Expanded(
                        child: TabBarView(
                          controller: _tabController,
                          children: [
                            _TimetableTab(
                              stops: state.stops,
                              serviceDate: widget.date,
                              delayMinutes:
                                  state.liveDelayMinutes ?? widget.delayMinutes,
                              delayUpdatedAt: state.delayUpdatedAt,
                              userOrigin: widget.userOrigin,
                              alight: _alightTarget ?? widget.userDest,
                              picking: _alightMode == _AlightMode.picking,
                              leadStops: _alightLead,
                              onPickStop: _pickAlight,
                            ),
                            _InfoTab(
                              type: widget.type,
                              trainNo: widget.trainNo,
                              stops: state.stops,
                              fullFare: state.fullFare,
                              userFare: state.userFare,
                              userOrigin: widget.userOrigin,
                              userDest: widget.userDest,
                              marks: widget.marks,
                              remark: widget.remark,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
            }
          },
        ),
      ),
    );
  }
}

/// The pinned 訂購 action. Opens the operator's own booking flow — the app
/// never sells tickets itself — so the label says where the tap leads.
class _BookingBar extends StatelessWidget {
  const _BookingBar({
    required this.isThsr,
    required this.trainNo,
    required this.date,
    required this.origin,
    required this.destination,
    required this.departTime,
    required this.fareQuote,
    required this.trainType,
    required this.hasBikeService,
  });

  final bool isThsr;
  final String trainNo;

  /// Backend train-type label, and whether this train carries bicycles. They
  /// gate the TRA booking classes: 騰雲座艙 exists only on 新自強, 兩鐵 only on
  /// bike-carrying trains.
  final String trainType;
  final bool hasBikeService;
  final String date;
  final String origin;
  final String destination;

  /// `HH:mm` departure from [origin]. THSR's deeplink needs it; TRA ignores it.
  final String departTime;

  final RailFareQuote? fareQuote;

  void _openSheet(BuildContext context) {
    unawaited(
      showRailBookingSheet(
        context,
        RailBookingRequest(
          isThsr: isThsr,
          origin: origin,
          destination: destination,
          date: date,
          time: departTime,
          trainNumber: trainNo,
        ),
        trainType: trainType,
        hasBikeService: hasBikeService,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        border: Border(top: BorderSide(color: cs.outlineVariant, width: 0.5)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppTheme.space16,
            AppTheme.space10,
            AppTheme.space16,
            AppTheme.space10,
          ),
          child: Pressable(
            onTap: () => _openSheet(context),
            semanticLabel: AppI18n.of(context).railBookTicketSemantics(trainNo),
            child: Container(
              height: 48,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: cs.primary,
                borderRadius: BorderRadius.circular(AppTheme.radiusButton),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    AppI18n.of(context).railBook,
                    style: AppTextStyles.bodyLarge.copyWith(
                      color: cs.onPrimary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  FarePreferenceBuilder(
                    builder: (context, fareType) {
                      final resolved = fareQuote?.resolve(fareType);
                      if (resolved == null || resolved.price <= 0) {
                        return const SizedBox.shrink();
                      }
                      final suffix = resolved.matched == FareType.full
                          ? ''
                          : ' ${resolved.matched.labelOf(AppI18n.of(context))}';
                      return Padding(
                        padding: const EdgeInsets.only(left: AppTheme.space8),
                        child: Text(
                          'NT\$ ${resolved.price}$suffix',
                          style: AppTextStyles.timeValue(
                            size: 14,
                            weight: FontWeight.w600,
                            color: cs.onPrimary.withValues(alpha: 0.82),
                          ),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
