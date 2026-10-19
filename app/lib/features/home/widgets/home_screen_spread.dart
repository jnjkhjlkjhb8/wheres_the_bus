part of '../home_screen.dart';

extension _HomeScreenSpreadX on _HomeScreenState {
  void _openStopBloc(NearStationViewModel station) {
    _releaseStopBloc();
    final origin = LatLng(station.lat, station.lon);
    _spreadKey = '${station.type.name}:${station.stationId}';
    _memberSignature = null;
    _spreadParts = const [];
    _memberRevision++;
    _memberMarkers.value = const {};
    _spreadPhase.value = _SpreadPhase.holding;
    // Hand the pin over before the nearby set drops it, so the map never
    // blinks where the user just tapped.
    unawaited(_holdGroupPin(station));
    _spread.value = (
      origin: origin,
      members: const [],
      labels: const {},
      selectedUid: null,
    );
    final bloc = BusStopBloc(
      i18n: AppI18n.of(context),
      stopId: station.stationId,
      repository: widget.busRepository,
    );
    _stopBloc = bloc;
    _stopSub = bloc.stream.listen((state) => _onStopState(origin, state));
  }

  // One expression: the order of cancel and close is not observable, so it
  // is not spelled as two statements.
  void _releaseStopBloc() => unawaited(
    Future.wait([?_stopSub?.cancel(), ?_stopBloc?.close()]),
  );

  void _onStopState(LatLng origin, BusStopState state) {
    if (!mounted) return;
    if (_spread.value == null) return;
    final labels = memberStopLabels(state.members, state.arrivalsByStation);
    final arrived = _membersJustArrived(state);
    _spread.value = (
      origin: origin,
      members: state.members,
      labels: labels,
      selectedUid: state.selectedStationUid,
    );
    final signature = (
      members: state.members.length,
      selected: state.selectedStationUid,
      labels: Object.hashAll(labels.values),
    );
    if (signature == _memberSignature) return;
    _memberSignature = signature;
    _resolveSpreadParts(_spread.value!);
    _refreshSpread(state.members, arrived: arrived);
  }

  bool _membersJustArrived(BusStopState state) =>
      _spread.value!.members.isEmpty && state.members.isNotEmpty;

  void _refreshSpread(List<BusStationMember> members, {required bool arrived}) {
    if (arrived) {
      unawaited(_openSpread(members));
    } else if (_spreadPhase.value == _SpreadPhase.open) {
      // A selection or label refresh only changes existing pole markers.
      unawaited(_publishMemberMarkers());
    }
  }

  Future<void> _openSpread(List<BusStationMember> members) async {
    await _fitMembers(members);
    if (!_spreadStillHolding) return;
    // One publish, so the holding pin is replaced by the poles in the same
    // marker-set write rather than the map going empty between two.
    await _publishMemberMarkers();
    if (!_spreadStillHolding) return;
    _spreadPhase.value = _SpreadPhase.open;
  }

  bool get _spreadStillHolding {
    if (!mounted) return false;
    return _spreadPhase.value == _SpreadPhase.holding;
  }

  /// Drops the group and gives its pin back to the nearby set.
  void _collapseSpread() {
    _releaseStopBloc();
    _stopSub = null;
    _stopBloc = null;
    _memberSignature = null;
    _endSpread();
  }

  /// Clears everything the open group owned and gives its pin back to the
  /// nearby set.
  void _endSpread() {
    _spreadPhase.value = _SpreadPhase.idle;
    _spreadKey = null;
    _spread.value = null;
    _spreadParts = const [];
    _memberRevision++;
    _memberMarkers.value = const {};
    unawaited(_rebuildMarkers(_stations));
  }

  void _selectMember(String? stationUid) {
    _stopBloc?.add(BusStopStationSelected(stationUid));
  }
}
