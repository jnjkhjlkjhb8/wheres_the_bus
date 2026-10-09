import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/models/journey_info.dart';
import 'package:wheres_the_bus/data/repositories/mrt_repository.dart';
import 'package:wheres_the_bus/features/metro/bloc/metro_bloc.dart';
import 'package:wheres_the_bus/features/metro/bloc/metro_event.dart';

const _info = JourneyInfo(
  toStationId: 'BL02',
  fareNt: 20,
  halfFareNt: 10,
  travelTimeMin: 5,
);

void main() {
  test('matrix loaded stores journey matrix', () async {
    final bloc = MetroBloc();
    addTearDown(bloc.close);

    bloc.add(const MetroJourneyMatrixLoaded(matrix: {'BL02': _info}));
    final state = await bloc.stream.first;

    expect(state.journeyMatrix?['BL02']?.fareNt, 20);
  });

  test('dismiss clears active station and matrix', () async {
    final bloc = MetroBloc();
    addTearDown(bloc.close);

    bloc
      ..add(const MetroJourneyMatrixLoaded(matrix: {'BL02': _info}))
      ..add(const MetroStationDismissed());
    final state = await bloc.stream.firstWhere(
      (s) => s.journeyMatrix == null,
    );

    expect(state.activeStationId, isNull);
    expect(state.journeyMatrix, isNull);
  });

  test(
    'a stale journey-matrix fetch resolving after a newer tap does not '
    'overwrite the newer station',
    () async {
      final stationA = Completer<Map<String, JourneyInfo>>();
      final stationB = Completer<Map<String, JourneyInfo>>();
      final repository = _ControlledMrtRepository({
        'A': stationA,
        'B': stationB,
      });
      final bloc = MetroBloc(repository: repository);
      addTearDown(bloc.close);

      bloc
        ..add(const MetroStationTapped(stationId: 'A'))
        ..add(const MetroStationTapped(stationId: 'B'));

      // The second tap's fetch (B) resolves first...
      stationB.complete({'BL02': _info});
      await pumpEventQueue();
      // ...then the stale first tap's fetch (A) resolves after it.
      stationA.complete({'R01': _info});
      await pumpEventQueue();

      expect(bloc.state.activeStationId, 'B');
      expect(bloc.state.journeyMatrix, {'BL02': _info});
    },
  );
}

class _ControlledMrtRepository extends MrtRepository {
  _ControlledMrtRepository(this.byStation);

  final Map<String, Completer<Map<String, JourneyInfo>>> byStation;

  @override
  Future<Map<String, JourneyInfo>> journeyMatrix(String stationId) =>
      byStation[stationId]!.future;
}
