import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart';
import 'package:wheres_the_bus/core/errors/app_error.dart';
import 'package:wheres_the_bus/data/models/tra_models.dart';
import 'package:wheres_the_bus/data/repositories/tra_repository.dart';
import 'package:wheres_the_bus/features/rail/bloc/rail_train_bloc.dart';
import 'package:wheres_the_bus/features/rail/bloc/rail_train_event.dart';
import 'package:wheres_the_bus/features/rail/bloc/rail_train_state.dart';

// Fare resolution hits PowerSync, which is uninitialized under `flutter test`;
// that throws and _loadFare swallows it, so fullFare is always null here. These
// tests therefore cover stops mapping and status transitions only.

void main() {
  RailTrainBloc bloc(TraRepository tra) => RailTrainBloc(
    type: '台鐵',
    trainNo: '123',
    date: '2026-07-07',
    tra: tra,
  );

  test('stops loaded -> loaded state with mapped stops', () async {
    final b = bloc(
      _FakeTraRepository(
        stopsResult: const [
          TraStopTime(
            stationName: '台北',
            arrivalTime: '',
            departureTime: '08:00',
            sequence: 1,
          ),
          TraStopTime(
            stationName: '台中',
            arrivalTime: '09:00',
            departureTime: '09:02',
            sequence: 2,
          ),
          TraStopTime(
            stationName: '高雄',
            arrivalTime: '11:00',
            departureTime: '',
            sequence: 3,
          ),
        ],
      ),
    );
    addTearDown(b.close);

    final next = expectLater(
      b.stream,
      emitsThrough(
        isA<RailTrainState>()
            .having((s) => s.status, 'status', RailTrainStatus.loaded)
            .having((s) => s.stops.length, 'stops.length', 3)
            .having((s) => s.stops.first.name, 'first', '台北')
            .having((s) => s.stops.last.name, 'last', '高雄'),
      ),
    );

    b.add(const RailTrainStarted());
    await next;
  });

  test('empty stops -> empty state', () async {
    final b = bloc(_FakeTraRepository());
    addTearDown(b.close);

    final next = expectLater(
      b.stream,
      emitsThrough(
        isA<RailTrainState>().having(
          (s) => s.status,
          'status',
          RailTrainStatus.empty,
        ),
      ),
    );

    b.add(const RailTrainStarted());
    await next;
  });

  test('NotFound -> empty state (not error)', () async {
    final b = bloc(
      _FakeTraRepository(error: const GrpcError.notFound('no train')),
    );
    addTearDown(b.close);

    final next = expectLater(
      b.stream,
      emitsThrough(
        isA<RailTrainState>().having(
          (s) => s.status,
          'status',
          RailTrainStatus.empty,
        ),
      ),
    );

    b.add(const RailTrainStarted());
    await next;
  });

  test('non-NotFound error -> error state', () async {
    final b = bloc(
      _FakeTraRepository(error: const GrpcError.unavailable('offline')),
    );
    addTearDown(b.close);

    final next = expectLater(
      b.stream,
      emitsThrough(
        isA<RailTrainState>()
            .having((s) => s.status, 'status', RailTrainStatus.error)
            .having((s) => s.error, 'error', isA<OfflineError>()),
      ),
    );

    b.add(const RailTrainStarted());
    await next;
  });

  test('loaded state has null fare when resolution unavailable', () async {
    final b = bloc(
      _FakeTraRepository(
        stopsResult: const [
          TraStopTime(
            stationName: '台北',
            arrivalTime: '',
            departureTime: '08:00',
            sequence: 1,
          ),
          TraStopTime(
            stationName: '高雄',
            arrivalTime: '11:00',
            departureTime: '',
            sequence: 2,
          ),
        ],
      ),
    );
    addTearDown(b.close);

    final next = expectLater(
      b.stream,
      emitsThrough(
        isA<RailTrainState>()
            .having((s) => s.status, 'status', RailTrainStatus.loaded)
            .having((s) => s.fullFare, 'fullFare', isNull),
      ),
    );

    b.add(const RailTrainStarted());
    await next;
  });

  test('TRA live delay frame updates liveDelayMinutes', () async {
    final repo = _FakeTraRepository(
      stopsResult: const [
        TraStopTime(
          stationName: '台北',
          arrivalTime: '',
          departureTime: '08:00',
          sequence: 1,
        ),
        TraStopTime(
          stationName: '台中',
          arrivalTime: '09:00',
          departureTime: '',
          sequence: 2,
        ),
      ],
    )..delayStream = Stream.value(const {'123': 7});

    final b = RailTrainBloc(
      type: '台鐵',
      trainNo: '123',
      date: '2026-07-20',
      tra: repo,
    );
    addTearDown(b.close);

    b.add(const RailTrainStarted());
    final s = await b.stream.firstWhere((s) => s.liveDelayMinutes == 7);
    expect(s.liveDelayMinutes, 7);
  });

  test('closing during load does not add to a closed bloc', () async {
    final repo = _FakeTraRepository(
      stopsResult: const [
        TraStopTime(
          stationName: '台北',
          arrivalTime: '',
          departureTime: '08:00',
          sequence: 1,
        ),
        TraStopTime(
          stationName: '台中',
          arrivalTime: '09:00',
          departureTime: '',
          sequence: 2,
        ),
      ],
    )..delayStream = Stream.value(const {'123': 7});

    Object? uncaught;
    await runZonedGuarded(() async {
      final b = RailTrainBloc(
        type: '台鐵',
        trainNo: '123',
        date: '2026-07-20',
        tra: repo,
      )..add(const RailTrainStarted());
      await b.close(); // awaits the in-flight handler to completion
      // Let any leaked delay frame land after close.
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }, (error, _) => uncaught = error);

    expect(uncaught, isNull);
  });
}

class _FakeTraRepository implements TraRepository {
  _FakeTraRepository({this.stopsResult = const [], this.error});

  final List<TraStopTime> stopsResult;
  final Exception? error;

  /// Live delay frames the bloc subscribes after stops load (TRA only).
  Stream<Map<String, int>> delayStream = const Stream.empty();

  @override
  Future<List<TraStopTime>> stops(String date, String trainNo) async {
    if (error != null) throw error!;
    return stopsResult;
  }

  @override
  Stream<Map<String, int>> delay(String date, String origin, String dest) =>
      delayStream;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} not faked');
}
