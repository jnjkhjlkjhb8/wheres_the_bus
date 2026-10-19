import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/core/errors/app_error.dart';
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
  test('a failed old matrix cannot replace the newer station result', () async {
    final a = Completer<Map<String, JourneyInfo>>();
    final b = Completer<Map<String, JourneyInfo>>();
    final bloc = MetroBloc(
      repository: _ControlledMrtRepository({'A': a, 'B': b}),
    );
    addTearDown(bloc.close);
    bloc.add(const MetroStationTapped(stationId: 'A'));
    await pumpEventQueue();
    bloc.add(const MetroStationTapped(stationId: 'B'));
    await pumpEventQueue();
    b.complete({'BL02': _info});
    await pumpEventQueue();
    a.completeError(StateError('old request failed'));
    await pumpEventQueue();
    expect(bloc.state.activeStationId, 'B');
    expect(bloc.state.error, isNull);
    expect(bloc.state.journeyMatrix, {'BL02': _info});
  });

  test(
    'current matrix failure surfaces an error and dismissal clears it',
    () async {
      final result = Completer<Map<String, JourneyInfo>>();
      final bloc = MetroBloc(
        repository: _ControlledMrtRepository({'A': result}),
      );
      addTearDown(bloc.close);
      bloc.add(const MetroStationTapped(stationId: 'A'));
      await pumpEventQueue();
      result.completeError(StateError('local data unavailable'));
      await pumpEventQueue();
      expect(bloc.state.error, isA<AppError>());
      bloc.add(const MetroStationDismissed());
      await pumpEventQueue();
      expect(bloc.state.error, isNull);
      expect(bloc.state.activeStationId, isNull);
    },
  );
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

  test(
    'a new tap shows its station at once, without the previous matrix',
    () async {
      final a = Completer<Map<String, JourneyInfo>>();
      final b = Completer<Map<String, JourneyInfo>>();
      final bloc = MetroBloc(
        repository: _ControlledMrtRepository({'A': a, 'B': b}),
      );
      addTearDown(bloc.close);
      bloc.add(const MetroStationTapped(stationId: 'A'));
      await pumpEventQueue();
      expect(bloc.state.activeStationId, 'A');
      expect(bloc.state.journeyMatrix, isNull);
      a.complete({'BL02': _info});
      await pumpEventQueue();
      expect(bloc.state.journeyMatrix, {'BL02': _info});

      bloc.add(const MetroStationTapped(stationId: 'B'));
      await pumpEventQueue();
      expect(bloc.state.activeStationId, 'B');
      expect(bloc.state.journeyMatrix, isNull);
      expect(bloc.state.error, isNull);
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
