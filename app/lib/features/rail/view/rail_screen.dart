import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:skeletonizer/skeletonizer.dart';
import 'package:smooth_sheets/smooth_sheets.dart';
import 'package:wheres_the_bus/app/router/app_routes.dart';
import 'package:wheres_the_bus/app/theme/app_text_styles.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/features/rail/bloc/rail_bloc.dart';
import 'package:wheres_the_bus/features/rail/bloc/rail_event.dart';
import 'package:wheres_the_bus/features/rail/bloc/rail_state.dart';
import 'package:wheres_the_bus/features/rail/view/rail_train_screen.dart';
import 'package:wheres_the_bus/features/rail/widgets/rail_query_sheet.dart';
import 'package:wheres_the_bus/features/rail/widgets/rail_service_marks.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/motion/app_motion.dart';
import 'package:wheres_the_bus/shared/motion/pressable.dart';
import 'package:wheres_the_bus/shared/widgets/app_bars.dart';
import 'package:wheres_the_bus/shared/widgets/bottom_sheet_shell.dart';
import 'package:wheres_the_bus/shared/widgets/error_state_view.dart';
import 'package:wheres_the_bus/shared/widgets/train_type_chip.dart';

part '../widgets/rail_shimmer_widgets.dart';
part '../widgets/rail_timetable_row_widgets.dart';

final _dateFormat = DateFormat('yyyy-MM-dd');

// One timetable row: the exact fields the row renders, times as "HH:mm".
typedef _RailRow = ({
  String type,
  String number,
  int delay,
  String depart,
  String arrive,
  String duration,
  List<RailServiceMark> marks,
  String remark,
  bool isSuspended,
  bool isAddedService,
});

// Built per call rather than held in a const map: the names follow the
// rider's language.
Map<int, String> _weekdayMap(AppI18n i18n) => {
  DateTime.monday: i18n.weekdayMon,
  DateTime.tuesday: i18n.weekdayTue,
  DateTime.wednesday: i18n.weekdayWed,
  DateTime.thursday: i18n.weekdayThu,
  DateTime.friday: i18n.weekdayFri,
  DateTime.saturday: i18n.weekdaySat,
  DateTime.sunday: i18n.weekdaySun,
};

String _formatDateDisplay(AppI18n i18n, DateTime date) {
  return '${date.month.toString().padLeft(2, '0')}/${date.day.toString().padLeft(2, '0')} (${_weekdayMap(i18n)[date.weekday]})';
}

/// Normalizes a backend time to `HH:mm`, accepting both an RFC3339 timestamp
/// (`2026-07-08T06:59:00+08:00`) and a bare `HH:mm:ss.ffffff` clock string.
String _railHhmm(String t) {
  final s = t.contains('T') ? t.split('T').last : t;
  return s.length >= 5 ? s.substring(0, 5) : s;
}

/// Minutes since midnight for an `HH:mm` clock string, or null when it does
/// not parse — a malformed time must not silently sort as 00:00.
int? _minutesOfDay(String hhmm) {
  final parts = hhmm.split(':');
  if (parts.length != 2) return null;
  final h = int.tryParse(parts[0]);
  final m = int.tryParse(parts[1]);
  if (h == null || m == null) return null;
  return h * 60 + m;
}

String _computeDuration(AppI18n i18n, String depart, String arrive) {
  final dParts = depart.split(':');
  final aParts = arrive.split(':');
  if (dParts.length != 2 || aParts.length != 2) return '';
  final dMin =
      (int.tryParse(dParts[0]) ?? 0) * 60 + (int.tryParse(dParts[1]) ?? 0);
  var aMin =
      (int.tryParse(aParts[0]) ?? 0) * 60 + (int.tryParse(aParts[1]) ?? 0);
  if (aMin < dMin) aMin += 24 * 60;
  final diff = aMin - dMin;
  final h = diff ~/ 60;
  final m = diff % 60;
  if (h == 0) return i18n.durationMinutes(m);
  if (m == 0) return i18n.hoursValue(h);
  return i18n.hoursMinutesValue(h, m);
}

class RailScreen extends StatefulWidget {
  const RailScreen({super.key, this.args});

  /// The query carried by `/rail` — see [RailRouteArgs]. Null, or one with no
  /// origin, opens the empty form exactly as the nav entry point does.
  final RailRouteArgs? args;

  @override
  State<RailScreen> createState() => _RailScreenState();
}

class _RailScreenState extends State<RailScreen> {
  final _bloc = RailBloc();
  RailSystem _system = RailSystem.tra;
  // Header + retry state, mirrored from the most recent O/D submission. The
  // query form itself lives in [RailQuerySheetContent]; these fields only feed
  // the top pill and the pull-to-refresh / error retry re-dispatch.
  String _originName = '';
  String _originId = '';
  String _destName = '';
  String _destId = '';
  late final SheetController _sheetController;
  DateTime _selectedDate = DateTime.now();
  bool _isDeparture = true;
  bool _hasSubmittedQuery = false;
  RailQueryPreset? _preset;

  // Drives the "N 分後" countdown on the next departure. The values are
  // minute-granular, so a minute tick is as often as the display can change;
  // it only rebuilds the visible rows of a lazily-built list.
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _sheetController = SheetController();
    _ticker = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
    _applyRouteArgs();
  }

  void _applyRouteArgs() {
    final args = widget.args;
    // No origin means a bare `/rail`: the empty form, with nothing to seed and
    // nothing to submit.
    if (args == null || args.originName.isEmpty) return;

    _system = args.system;
    _originName = args.originName;
    // A near station's id is already a valid tra/thsr station_id, so carry it
    // directly rather than re-resolving by name.
    _originId = args.originId;
    _destName = args.destName;
    // A location can name the same station twice; clear the dest rather than
    // carry a zero-length trip into the form.
    if (_originName == _destName) _destName = '';
    _destId = args.destId;
    // Null means "now" — resolved here rather than in the location, so a
    // restored or shared link is not stuck at the time it was made.
    _selectedDate = args.date ?? DateTime.now();
    _isDeparture = args.isDeparture;
    // Seed the form with the full effective query (not just the origin) so the
    // sheet and the auto-submitted results can't disagree.
    _preset = RailQueryPreset(
      system: _system,
      originName: _originName,
      originId: args.originId,
      destName: _destName,
      destId: args.destId,
      date: _selectedDate,
      isDeparture: _isDeparture,
    );

    // An origin-only location has nothing to submit: it opens the form with the
    // origin filled and waits for a destination.
    if (!args.submit || _destName.isEmpty) return;
    // A full O/D location (from the home sheet): run it immediately and drop
    // the query sheet out of the way so results are the first thing shown.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() => _hasSubmittedQuery = true);
      _dispatchSearch();
      unawaited(
        _sheetController.animateToDetent(
          AppSheetSnap.peek,
          reduced: AppMotion.reduced(context),
        ),
      );
    });
  }

  // Derived card rows, cached per loaded-state instance so local setState
  // (date picks, station picks, sheet drags) doesn't re-parse every train's
  // times; states are immutable, so identity is a sound cache key.
  RailTimetableLoaded? _rowsSource;
  late List<_RailRow> _rowsCache;

  List<_RailRow> _rowsFor(RailTimetableLoaded state) {
    if (!identical(state, _rowsSource)) {
      _rowsSource = state;
      _rowsCache = [
        for (final item in state.traItems)
          (
            type: item.trainType,
            number: item.trainNo,
            delay: state.delays[item.trainNo] ?? 0,
            depart: _railHhmm(item.departureTime),
            arrive: _railHhmm(item.arrivalTime),
            duration: _computeDuration(
              AppI18n.of(context),
              _railHhmm(item.departureTime),
              _railHhmm(item.arrivalTime),
            ),
            marks: RailServiceMark.forTra(item),
            remark: item.remark,
            isSuspended: item.isSuspended,
            isAddedService: item.isAddedService,
          ),
        for (final item in state.thsrItems)
          (
            type: '高鐵',
            number: item.trainNo,
            delay: state.delays[item.trainNo] ?? 0,
            depart: _railHhmm(item.departureTime),
            arrive: _railHhmm(item.arrivalTime),
            duration: _computeDuration(
              AppI18n.of(context),
              _railHhmm(item.departureTime),
              _railHhmm(item.arrivalTime),
            ),
            marks: RailServiceMark.forThsr(item),
            remark: item.remark,
            isSuspended: false,
            isAddedService: false,
          ),
      ];
    }
    return _rowsCache;
  }

  (int?, int?) _nextDeparture(List<_RailRow> rows, String date) {
    final now = DateTime.now();
    if (date != _dateFormat.format(now)) return (null, null);
    final nowMinutes = now.hour * 60 + now.minute;
    for (var i = 0; i < rows.length; i++) {
      if (rows[i].isSuspended) continue;
      final depart = _minutesOfDay(rows[i].depart);
      if (depart == null || depart < nowMinutes) continue;
      return (i, depart - nowMinutes);
    }
    return (null, null);
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _sheetController.dispose();
    unawaited(_bloc.close());
    super.dispose();
  }

  void _onSystemChanged(RailSystem system) {
    setState(() {
      _system = system;
      _hasSubmittedQuery = false;
    });
    // Clear stale results back to the prompt (no query until user searches).
    _bloc.add(RailSystemChanged(system));
  }

  void _onSubmit(RailQuerySubmission submission) {
    switch (submission) {
      case RailOdQuerySubmission():
        setState(() {
          _system = submission.system;
          _originName = submission.originName;
          _originId = submission.originId ?? '';
          _destName = submission.destName;
          _destId = submission.destId ?? '';
          _selectedDate = submission.date;
          _isDeparture = submission.isDeparture;
          _hasSubmittedQuery = true;
        });
        _dispatchSearch();
        // Collapse the inline sheet to reveal results. Never pop the navigator
        // here — the sheet is part of this screen's Stack, so popping unwinds
        // back to home.
        unawaited(
          _sheetController.animateToDetent(
            AppSheetSnap.peek,
            reduced: AppMotion.reduced(context),
          ),
        );
      case RailTrainQuerySubmission():
        unawaited(
          context.push(
            AppRoutes.railTrain(
              submission.trainNo,
              system: submission.system,
              date: submission.date,
            ),
          ),
        );
    }
  }

  void _dispatchSearch() {
    _hasSubmittedQuery = true;
    _bloc.add(
      RailTimetableRequested(
        system: _system,
        origin: RailStationSelection(
          name: _originName,
          id: _originId.isEmpty ? null : _originId,
        ),
        destination: RailStationSelection(
          name: _destName,
          id: _destId.isEmpty ? null : _destId,
        ),
        date: _dateFormat.format(_selectedDate),
        cutoffMinutes: _selectedDate.hour * 60 + _selectedDate.minute,
        isDeparture: _isDeparture,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final topPad = MediaQuery.paddingOf(context).top;

    return BlocProvider.value(
      value: _bloc,
      child: Scaffold(
        body: Stack(
          children: [
            Positioned.fill(
              child: ColoredBox(
                color: cs.surface,
                child: BlocBuilder<RailBloc, RailState>(
                  builder: (context, state) {
                    if (state is RailError) {
                      return ListView(
                        padding: EdgeInsets.fromLTRB(
                          AppTheme.space16,
                          topPad + 68,
                          AppTheme.space16,
                          AppTheme.space16,
                        ),
                        children: [
                          ErrorStateView(
                            error: state.error,
                            onRetry: _dispatchSearch,
                          ),
                        ],
                      );
                    }
                    if (state is RailTimetableLoading) {
                      // Full-bleed and offset exactly like the loaded list
                      // below (topPad + 68 + 12), so the table doesn't shift
                      // when the trains arrive.
                      return ListView(
                        padding: EdgeInsets.only(
                          top: topPad + 68 + AppTheme.space12,
                          bottom: AppTheme.space16,
                        ),
                        children: const [_TimetableSkeleton()],
                      );
                    }
                    if (state is! RailTimetableLoaded) {
                      // No search run yet — prompt instead of auto-querying a
                      // placeholder O/D pair.
                      return Padding(
                        padding: EdgeInsets.fromLTRB(
                          AppTheme.space24,
                          topPad + 68,
                          AppTheme.space24,
                          AppTheme.space24,
                        ),
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.train_rounded,
                                size: 40,
                                color: cs.outline,
                              ),
                              const SizedBox(height: AppTheme.space16),
                              Text(
                                AppI18n.of(context).railPickStations,
                                textAlign: TextAlign.center,
                                style: AppTextStyles.bodyRegular.copyWith(
                                  color: cs.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }
                    final items = _rowsFor(state);
                    if (items.isEmpty) {
                      return ListView(
                        padding: EdgeInsets.fromLTRB(
                          AppTheme.space24,
                          topPad + 68,
                          AppTheme.space24,
                          AppTheme.space24,
                        ),
                        children: const [_NoTimetableEmpty()],
                      );
                    }
                    final (nextIndex, minutesUntil) = _nextDeparture(
                      items,
                      state.date,
                    );
                    return ValueListenableBuilder<double?>(
                      valueListenable: _sheetController,
                      child: SliverMainAxisGroup(
                        slivers: [
                          SliverToBoxAdapter(
                            child: Padding(
                              padding: EdgeInsets.only(
                                top: topPad + 68 + AppTheme.space12,
                              ),
                              child: const _TimetableHeader(),
                            ),
                          ),
                          SliverList.separated(
                            itemCount: items.length,
                            separatorBuilder: (context, i) => Divider(
                              height: 1,
                              thickness: 1,
                              indent: 16,
                              color: cs.outlineVariant.withValues(alpha: 0.4),
                            ),
                            itemBuilder: (context, i) => _TrainRow(
                              row: items[i],
                              system: _system,
                              date: state.date,
                              origin: state.originName,
                              destination: state.destName,
                              isNext: i == nextIndex,
                              minutesUntil: minutesUntil,
                            ),
                          ),
                        ],
                      ),
                      builder: (context, offset, listSliver) {
                        return RefreshIndicator(
                          onRefresh: () async => _dispatchSearch(),
                          child: CustomScrollView(
                            physics: const AlwaysScrollableScrollPhysics(),
                            slivers: [
                              listSliver!,
                              SliverToBoxAdapter(
                                child: SizedBox(height: (offset ?? 0.0) + 16),
                              ),
                            ],
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            ),

            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: FloatingAppBar(
                middle: AppBarTitlePill(
                  title: _hasSubmittedQuery
                      ? '$_originName → $_destName'
                      : AppI18n.of(context).railTimetableTitle,
                  subtitle: _formatDateDisplay(
                    AppI18n.of(context),
                    _selectedDate,
                  ),
                ),
              ),
            ),

            // RailQuerySheetContent starts its ListView flush with the sheet's
            // top edge and can't take a SafeArea itself; AppSheet's own
            // status-bar padding is what keeps its handle and title clear.
            AppSheet(
              controller: _sheetController,
              color: cs.surface,
              child: RailQuerySheetContent(
                preset: _preset,
                onSubmit: _onSubmit,
                onSystemChanged: _onSystemChanged,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A successful timetable query with zero departures in the requested
/// window — distinct from [ErrorStateView], which implies the request
/// itself failed and a retry might help.
class _NoTimetableEmpty extends StatelessWidget {
  const _NoTimetableEmpty();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.event_busy_rounded,
            size: 40,
            color: AppTheme.inkTertiary(cs.brightness),
          ),
          const SizedBox(height: AppTheme.space16),
          Text(
            AppI18n.of(context).railNoTrains,
            textAlign: TextAlign.center,
            style: AppTextStyles.bodyRegular.copyWith(
              color: cs.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AppTheme.space6),
          Text(
            AppI18n.of(context).railNoTrainsHint,
            textAlign: TextAlign.center,
            style: AppTextStyles.bodySmall.copyWith(
              color: cs.outline,
            ),
          ),
        ],
      ),
    );
  }
}
