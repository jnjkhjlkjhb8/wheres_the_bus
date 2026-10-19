import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart';
import 'package:wheres_the_bus/core/errors/app_error.dart';
import 'package:wheres_the_bus/data/models/fare_type.dart';
import 'package:wheres_the_bus/data/models/thsr_models.dart';
import 'package:wheres_the_bus/data/models/tra_models.dart';
import 'package:wheres_the_bus/data/repositories/thsr_repository.dart';
import 'package:wheres_the_bus/data/repositories/tra_repository.dart';
import 'package:wheres_the_bus/features/rail/bloc/rail_train_bloc.dart';
import 'package:wheres_the_bus/features/rail/bloc/rail_train_event.dart';
import 'package:wheres_the_bus/features/rail/bloc/rail_train_state.dart';

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
  const fareStops = [
    TraStopTime(
      stationName: '台北',
      arrivalTime: '',
      departureTime: '08:00',
      sequence: 1,
    ),
    TraStopTime(
      stationName: '板橋',
      arrivalTime: '08:10',
      departureTime: '08:11',
      sequence: 2,
    ),
    TraStopTime(
      stationName: '台中',
      arrivalTime: '09:00',
      departureTime: '',
      sequence: 3,
    ),
  ];

  test('a partial TRA segment resolves both labelled fares', () async {
    final repo = _FakeTraRepository(
      stopsResult: fareStops,
      fareResult: const [TraFare(ticketType: '成自', price: 300)],
    );
    final b = RailTrainBloc(
      type: '自強',
      trainNo: '123',
      date: '2030-01-02',
      userOrigin: '板橋',
      userDest: '台中',
      tra: repo,
    );
    addTearDown(b.close);
    b.add(const RailTrainStarted());
    final loaded = await b.stream.firstWhere(
      (s) => s.status == RailTrainStatus.loaded,
    );
    expect(repo.fareCalls, [('台北', '台中'), ('板橋', '台中')]);
    expect(loaded.fullFare!.resolve(FareType.full)?.price, 300);
    expect(loaded.userFare!.resolve(FareType.full)?.price, 300);
  });

  test(
    'a full-run segment reuses one quote and live delay defaults to zero',
    () async {
      final repo = _FakeTraRepository(
        stopsResult: fareStops,
        fareResult: const [TraFare(ticketType: '成自', price: 300)],
      )..delayStream = Stream.value(const {'another-train': 7});
      final b = RailTrainBloc(
        type: '自強',
        trainNo: '123',
        date: '2030-01-02',
        userOrigin: '台北',
        userDest: '台中',
        tra: repo,
      );
      addTearDown(b.close);
      b.add(const RailTrainDelayUpdated(99));
      await pumpEventQueue();
      expect(b.state.liveDelayMinutes, isNull);
      b.add(const RailTrainStarted());
      final loaded = await b.stream.firstWhere((s) => s.liveDelayMinutes == 0);
      expect(repo.fareCalls, [('台北', '台中')]);
      expect(loaded.fullFare, same(loaded.userFare));
      expect(loaded.delayUpdatedAt, isNotNull);
    },
  );

  test(
    'THSR stops and fares resolve without subscribing to TRA delays',
    () async {
      final repo = _FareThsr();
      final b = RailTrainBloc(
        type: '高鐵',
        trainNo: '101',
        date: '2030-01-02',
        thsr: repo,
      );
      addTearDown(b.close);
      b.add(const RailTrainStarted());
      final loaded = await b.stream.firstWhere(
        (s) => s.status == RailTrainStatus.loaded,
      );
      expect(loaded.stops.map((s) => s.name), ['南港', '左營']);
      expect(loaded.fullFare!.resolve(FareType.full)?.price, 1490);
      expect(loaded.userFare, isNull);
      expect(loaded.liveDelayMinutes, isNull);
      expect(repo.fareCalls, [('2030-01-02', '南港', '左營')]);
    },
  );
}

class _FakeTraRepository implements TraRepository {
  _FakeTraRepository({
    this.stopsResult = const [],
    this.error,
    this.fareResult,
  });

  final List<TraStopTime> stopsResult;
  final Exception? error;
  final List<TraFare>? fareResult;
  final fareCalls = <(String, String)>[];

  @override
  Future<List<TraFare>> fares(String origin, String destination) async {
    fareCalls.add((origin, destination));
    return fareResult ?? (throw StateError('fare unavailable'));
  }

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

class _FareThsr implements ThsrRepository {
  final fareCalls = <(String, String, String)>[];
  @override
  Future<List<ThsrStopTime>> stops(String date, String trainNo) async => const [
    ThsrStopTime(
      stationName: '南港',
      arrivalTime: '',
      departureTime: '08:00',
      sequence: 1,
    ),
    ThsrStopTime(
      stationName: '左營',
      arrivalTime: '09:30',
      departureTime: '',
      sequence: 2,
    ),
  ];
  @override
  Future<List<ThsrFare>> fares(
    String date,
    String origin,
    String destination,
  ) async {
    fareCalls.add((date, origin, destination));
    return const [ThsrFare(fareClass: 1, price: 1490)];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} not faked');
}
