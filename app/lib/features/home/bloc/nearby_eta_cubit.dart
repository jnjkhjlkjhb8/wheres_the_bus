import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:wheres_the_bus/core/grpc/resilient_stream.dart';
import 'package:wheres_the_bus/data/models/bus_models.dart';
import 'package:wheres_the_bus/data/models/near_models.dart';
import 'package:wheres_the_bus/data/repositories/bus_repository.dart';
import 'package:wheres_the_bus/features/bus/bloc/bus_stop_state.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';

/// Next arrivals for the bus rows of the home nearby list, keyed by group
/// uid: at most two each, ranked as the stop page ranks them.
///
/// One stream covers the nearest groups. It is reopened only when that set
/// changes, held while the list is not on screen, and paused in the
/// background by [ResilientSubscription]. A server without the stream, or
/// one that keeps failing, leaves the rows without times rather than showing
/// an error: the times are extra on a list that already works.
class NearbyEtaCubit extends Cubit<Map<String, List<BusStopArrivalItem>>> {
  NearbyEtaCubit({
    required AppI18n i18n,
    BusRepository? repository,
    this.settle = const Duration(milliseconds: 600),
    @visibleForTesting ValueListenable<bool>? foreground,
  }) : _i18n = i18n,
       _repository = repository ?? BusRepository.instance,
       _foreground = foreground,
       super(const {});

  /// The server reads at most this many groups.
  static const maxGroups = 10;

  /// How long a new set of groups must hold before the stream is reopened,
  /// so a map drag does not open one stream per frame.
  final Duration settle;

  final AppI18n _i18n;
  final BusRepository _repository;
  final ValueListenable<bool>? _foreground;

  List<(String, String)> _groups = const [];
  bool _visible = true;
  Timer? _settleTimer;
  ResilientSubscription<Map<String, List<BusStopArrival>>>? _sub;

  /// Follows the nearest bus groups among [stations] (already nearest
  /// first).
  void watch(List<NearStationViewModel> stations) {
    final groups = [
      for (final s in stations)
        if (s.type == NearStationType.bus && s.city.isNotEmpty)
          (s.city, s.stationId),
    ].take(maxGroups).toList();
    if (setEquals(groups.toSet(), _groups.toSet())) return;
    _groups = groups;
    _settleTimer?.cancel();
    _settleTimer = Timer(settle, _reopen);
  }

  /// Holds the stream while the list is covered or scrolled out of the tab.
  void setVisible(bool visible) {
    if (visible == _visible) return;
    _visible = visible;
    _reopen();
  }

  void _reopen() {
    unawaited(_sub?.cancel());
    _sub = null;
    if (!_visible || _groups.isEmpty) return;
    final groups = _groups;
    _sub = ResilientSubscription(
      source: () => _repository.stationEtas(groups),
      onData: _onFrame,
      onFailure: (_) {
        if (!isClosed) emit(const {});
      },
      foreground: _foreground,
    );
  }

  void _onFrame(Map<String, List<BusStopArrival>> frame) {
    if (isClosed) return;
    emit({
      for (final MapEntry(:key, :value) in frame.entries) key: _soonest(value),
    });
  }

  /// Rows with a time, soonest first: service states such as 末班駛離 say
  /// nothing about when to leave.
  List<BusStopArrivalItem> _soonest(List<BusStopArrival> arrivals) =>
      ([
            for (final a in arrivals) BusStopArrivalItem(_i18n, a),
          ]..sort(_byRankThenRoute))
          .where((a) => a.rank < _untimedRank)
          .take(2)
          .toList();

  // List.sort is not stable; without a tie-break two buses due in the same
  // minute could swap places between frames.
  static int _byRankThenRoute(BusStopArrivalItem a, BusStopArrivalItem b) {
    final byRank = a.rank.compareTo(b.rank);
    return byRank != 0 ? byRank : a.display.label.compareTo(b.display.label);
  }

  /// ArrivalDisplay's rank for a row without a time.
  static const _untimedRank = 9999;

  @override
  Future<void> close() async {
    _settleTimer?.cancel();
    await _sub?.cancel();
    return super.close();
  }
}
