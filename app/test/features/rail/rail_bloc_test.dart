import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/core/errors/app_error.dart';
import 'package:wheres_the_bus/data/models/fare_type.dart';
import 'package:wheres_the_bus/data/models/thsr_models.dart';
import 'package:wheres_the_bus/data/models/tra_models.dart';
import 'package:wheres_the_bus/data/repositories/thsr_repository.dart';
import 'package:wheres_the_bus/data/repositories/tra_repository.dart';
import 'package:wheres_the_bus/features/rail/bloc/rail_bloc.dart';
import 'package:wheres_the_bus/features/rail/bloc/rail_event.dart';
import 'package:wheres_the_bus/features/rail/bloc/rail_state.dart';

void main() {
  test('one THSR request loads from the initial state', () async {
    const item = ThsrTimetableItem(
      trainNo: '101',
      departureTime: '08:00',
      arrivalTime: '09:30',
      travelMinutes: 90,
      delayMinutes: 0,
      remark: '',
    );
    final thsr = _FakeThsrRepository(timetableResult: const [item]);
    final bloc = RailBloc(thsrRepository: thsr);
    addTearDown(bloc.close);

    final states = expectLater(
      bloc.stream,
      emitsInOrder([
        isA<RailTimetableLoading>()
            .having((s) => s.system, 'system', RailSystem.thsr)
            .having((s) => s.originName, 'origin', '南港')
            .having((s) => s.destName, 'destination', '左營'),
        isA<RailTimetableLoaded>()
            .having((s) => s.system, 'system', RailSystem.thsr)
            .having((s) => s.thsrItems, 'items', const [item]),
      ]),
    );

    bloc.add(
      const RailTimetableRequested(
        system: RailSystem.thsr,
        origin: RailStationSelection(name: '南港', id: '0990'),
        destination: RailStationSelection(name: '左營', id: '1070'),
        date: '2026-07-10',
      ),
    );

    await states;
    expect(thsr.timetableCalls, [('2026-07-10', '0990', '1070')]);
  });

  test('loads the server fare into RailTimetableLoaded', () async {
    const item = ThsrTimetableItem(
      trainNo: '101',
      departureTime: '08:00',
      arrivalTime: '09:30',
      travelMinutes: 90,
      delayMinutes: 0,
      remark: '',
    );
    final thsr = _FakeThsrRepository(
      timetableResult: const [item],
      fareResult: const [ThsrFare(fareClass: 1, price: 1490)],
    );
    final bloc = RailBloc(thsrRepository: thsr);
    addTearDown(bloc.close);

    bloc.add(
      const RailTimetableRequested(
        system: RailSystem.thsr,
        origin: RailStationSelection(name: '南港', id: '0990'),
        destination: RailStationSelection(name: '左營', id: '1070'),
        date: '2026-07-10',
      ),
    );
    final loaded =
        await bloc.stream.firstWhere((state) => state is RailTimetableLoaded)
            as RailTimetableLoaded;

    expect(
      loaded.fareQuote?.resolve(FareType.full),
      (price: 1490, matched: FareType.full),
    );
  });

  test('fare query failure still loads the timetable (null fare)', () async {
    const item = ThsrTimetableItem(
      trainNo: '101',
      departureTime: '08:00',
      arrivalTime: '09:30',
      travelMinutes: 90,
      delayMinutes: 0,
      remark: '',
    );
    // No fareResult → the fake's fares() throws; _loadFares swallows it.
    final thsr = _FakeThsrRepository(timetableResult: const [item]);
    final bloc = RailBloc(thsrRepository: thsr);
    addTearDown(bloc.close);

    bloc.add(
      const RailTimetableRequested(
        system: RailSystem.thsr,
        origin: RailStationSelection(name: '南港', id: '0990'),
        destination: RailStationSelection(name: '左營', id: '1070'),
        date: '2026-07-10',
      ),
    );
    final loaded =
        await bloc.stream.firstWhere((state) => state is RailTimetableLoaded)
            as RailTimetableLoaded;

    expect(loaded.fareQuote, isNull);
    expect(loaded.thsrItems, const [item]);
  });

  test('cutoff drops earlier THSR trains and sorts the rest', () async {
    const early = ThsrTimetableItem(
      trainNo: '801',
      departureTime: '14:15',
      arrivalTime: '15:45',
      travelMinutes: 90,
      delayMinutes: 0,
      remark: '',
    );
    const late = ThsrTimetableItem(
      trainNo: '805',
      departureTime: '20:30',
      arrivalTime: '22:00',
      travelMinutes: 90,
      delayMinutes: 0,
      remark: '',
    );
    const mid = ThsrTimetableItem(
      trainNo: '803',
      departureTime: '19:10',
      arrivalTime: '20:40',
      travelMinutes: 90,
      delayMinutes: 0,
      remark: '',
    );
    final thsr = _FakeThsrRepository(timetableResult: const [early, late, mid]);
    final bloc = RailBloc(thsrRepository: thsr);
    addTearDown(bloc.close);

    bloc.add(
      const RailTimetableRequested(
        system: RailSystem.thsr,
        origin: RailStationSelection(name: '南港', id: '0990'),
        destination: RailStationSelection(name: '左營', id: '1070'),
        date: '2026-07-12',
        // Depart from 19:00 → drop the 14:15 train, keep 19:10 and 20:30.
        cutoffMinutes: 19 * 60,
      ),
    );
    final loaded =
        await bloc.stream.firstWhere((state) => state is RailTimetableLoaded)
            as RailTimetableLoaded;

    expect(loaded.thsrItems, const [mid, late]);
  });

  test('no cutoff keeps all THSR trains sorted by departure', () async {
    const early = ThsrTimetableItem(
      trainNo: '801',
      departureTime: '14:15',
      arrivalTime: '15:45',
      travelMinutes: 90,
      delayMinutes: 0,
      remark: '',
    );
    const late = ThsrTimetableItem(
      trainNo: '805',
      departureTime: '20:30',
      arrivalTime: '22:00',
      travelMinutes: 90,
      delayMinutes: 0,
      remark: '',
    );
    const mid = ThsrTimetableItem(
      trainNo: '803',
      departureTime: '19:10',
      arrivalTime: '20:40',
      travelMinutes: 90,
      delayMinutes: 0,
      remark: '',
    );
    final thsr = _FakeThsrRepository(timetableResult: const [early, late, mid]);
    final bloc = RailBloc(thsrRepository: thsr);
    addTearDown(bloc.close);

    bloc.add(
      const RailTimetableRequested(
        system: RailSystem.thsr,
        origin: RailStationSelection(name: '南港', id: '0990'),
        destination: RailStationSelection(name: '左營', id: '1070'),
        date: '2026-07-13',
        // No cutoff → the whole day stays, just sorted.
      ),
    );
    final loaded =
        await bloc.stream.firstWhere((state) => state is RailTimetableLoaded)
            as RailTimetableLoaded;

    expect(loaded.thsrItems, const [early, mid, late]);
  });

  test('arrive-by cutoff keeps trains landing in time, by arrival', () async {
    // Express (805) departs later but arrives earlier — proves the arrival sort
    // and filter, not the departure one.
    const slow = ThsrTimetableItem(
      trainNo: '801',
      departureTime: '06:00',
      arrivalTime: '11:00',
      travelMinutes: 300,
      delayMinutes: 0,
      remark: '',
    );
    const express = ThsrTimetableItem(
      trainNo: '805',
      departureTime: '07:00',
      arrivalTime: '10:00',
      travelMinutes: 180,
      delayMinutes: 0,
      remark: '',
    );
    const tooLate = ThsrTimetableItem(
      trainNo: '803',
      departureTime: '13:00',
      arrivalTime: '15:30',
      travelMinutes: 150,
      delayMinutes: 0,
      remark: '',
    );
    final thsr = _FakeThsrRepository(
      timetableResult: const [slow, express, tooLate],
    );
    final bloc = RailBloc(thsrRepository: thsr);
    addTearDown(bloc.close);

    bloc.add(
      const RailTimetableRequested(
        system: RailSystem.thsr,
        origin: RailStationSelection(name: '南港', id: '0990'),
        destination: RailStationSelection(name: '左營', id: '1070'),
        date: '2026-07-13',
        // Arrive by 12:00 → keep the two landing before it, drop the 15:30.
        cutoffMinutes: 12 * 60,
        isDeparture: false,
      ),
    );
    final loaded =
        await bloc.stream.firstWhere((state) => state is RailTimetableLoaded)
            as RailTimetableLoaded;

    expect(loaded.thsrItems, const [express, slow]);
  });

  test('known station IDs bypass repository lookup', () async {
    final thsr = _FakeThsrRepository();
    final bloc = RailBloc(thsrRepository: thsr);
    addTearDown(bloc.close);

    bloc.add(
      const RailTimetableRequested(
        system: RailSystem.thsr,
        origin: RailStationSelection(name: '南港', id: '0990'),
        destination: RailStationSelection(name: '左營', id: '1070'),
        date: '2026-07-10',
      ),
    );
    await bloc.stream.firstWhere((state) => state is RailTimetableLoaded);

    expect(thsr.timetableCalls, [('2026-07-10', '0990', '1070')]);
  });

  test('a name without an id is passed through as the RPC id', () async {
    final thsr = _FakeThsrRepository();
    final bloc = RailBloc(thsrRepository: thsr);
    addTearDown(bloc.close);

    bloc.add(
      const RailTimetableRequested(
        system: RailSystem.thsr,
        origin: RailStationSelection(name: '未知起點'),
        destination: RailStationSelection(name: '未知終點'),
        date: '2026-07-10',
      ),
    );
    await bloc.stream.firstWhere((state) => state is RailTimetableLoaded);

    expect(
      thsr.timetableCalls,
      [('2026-07-10', '未知起點', '未知終點')],
    );
  });

  test('TRA delay updates are attached to the loaded timetable', () async {
    final delays = StreamController<Map<String, int>>.broadcast();
    addTearDown(delays.close);
    final tra = _FakeTraRepository(delayStream: delays.stream);
    final bloc = RailBloc(traRepository: tra);
    addTearDown(bloc.close);

    bloc.add(
      const RailTimetableRequested(
        system: RailSystem.tra,
        origin: RailStationSelection(name: '台北', id: '1000'),
        destination: RailStationSelection(name: '花蓮', id: '7000'),
        date: '2026-07-10',
      ),
    );
    await bloc.stream.firstWhere((state) => state is RailTimetableLoaded);
    while (tra.delayCalls.isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }
    final delayed = bloc.stream.firstWhere(
      (state) => state is RailTimetableLoaded && state.delays['110'] == 3,
    );
    delays.add(const {'110': 3});

    expect((await delayed as RailTimetableLoaded).delays, const {'110': 3});
  });

  test(
    'switching TRA -> THSR cancels the old TRA delay subscription — a '
    'lingering TRA delay must not land on the THSR state (F21)',
    () async {
      final delays = StreamController<Map<String, int>>.broadcast();
      addTearDown(delays.close);
      final tra = _FakeTraRepository(delayStream: delays.stream);
      final thsr = _FakeThsrRepository(
        timetableResult: const [
          ThsrTimetableItem(
            trainNo: '101',
            departureTime: '08:00',
            arrivalTime: '09:30',
            travelMinutes: 90,
            delayMinutes: 0,
            remark: '',
          ),
        ],
      );
      final bloc = RailBloc(traRepository: tra, thsrRepository: thsr);
      addTearDown(bloc.close);

      bloc.add(
        const RailTimetableRequested(
          system: RailSystem.tra,
          origin: RailStationSelection(name: '台北', id: '1000'),
          destination: RailStationSelection(name: '花蓮', id: '7000'),
          date: '2026-07-10',
        ),
      );
      await bloc.stream.firstWhere((state) => state is RailTimetableLoaded);
      while (tra.delayCalls.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }

      bloc.add(
        const RailTimetableRequested(
          system: RailSystem.thsr,
          origin: RailStationSelection(name: '南港', id: '0990'),
          destination: RailStationSelection(name: '左營', id: '1070'),
          date: '2026-07-10',
        ),
      );
      final thsrLoaded =
          await bloc.stream.firstWhere(
                (state) =>
                    state is RailTimetableLoaded &&
                    state.system == RailSystem.thsr,
              )
              as RailTimetableLoaded;
      expect(thsrLoaded.delays, isEmpty);

      // A delay frame from the now-stale TRA stream must not reach the
      // THSR-loaded state, whether the subscription is truly cancelled or the
      // handler's own system check rejects it.
      delays.add(const {'110': 3});
      await pumpEventQueue();

      expect(bloc.state, isA<RailTimetableLoaded>());
      expect((bloc.state as RailTimetableLoaded).system, RailSystem.thsr);
      expect((bloc.state as RailTimetableLoaded).delays, isEmpty);
    },
  );

  test('repeat THSR requests remain on the THSR adapter', () async {
    final thsr = _FakeThsrRepository();
    final tra = _FakeTraRepository();
    final bloc = RailBloc(traRepository: tra, thsrRepository: thsr);
    addTearDown(bloc.close);

    RailTimetableRequested request(String date) => RailTimetableRequested(
      system: RailSystem.thsr,
      origin: const RailStationSelection(name: '南港', id: '0990'),
      destination: const RailStationSelection(name: '左營', id: '1070'),
      date: date,
    );

    bloc.add(request('2026-07-10'));
    await bloc.stream.firstWhere((state) => state is RailTimetableLoaded);
    bloc.add(request('2026-07-11'));
    await bloc.stream.firstWhere(
      (state) => state is RailTimetableLoaded && state.date == '2026-07-11',
    );

    expect(tra.timetableCalls, isEmpty);
    expect(thsr.timetableCalls, [
      ('2026-07-10', '0990', '1070'),
      ('2026-07-11', '0990', '1070'),
    ]);
  });

  test('repository failures become RailError', () async {
    final thsr = _FakeThsrRepository(error: StateError('boom'));
    final bloc = RailBloc(thsrRepository: thsr);
    addTearDown(bloc.close);

    bloc.add(
      const RailTimetableRequested(
        system: RailSystem.thsr,
        origin: RailStationSelection(name: '南港', id: '0990'),
        destination: RailStationSelection(name: '左營', id: '1070'),
        date: '2026-07-10',
      ),
    );

    final state = await bloc.stream.firstWhere((state) => state is RailError);
    expect((state as RailError).error, isA<UnknownError>());
  });

  test('RailBloc starts in initial state', () {
    final bloc = RailBloc();
    addTearDown(bloc.close);
    expect(bloc.state, isA<RailInitial>());
  });

  test(
    'RailTimetableLoaded delays updated via copyWith reflects pushed value',
    () {
      const trainNo = '110';
      const delayMinutes = 5;

      const loaded = RailTimetableLoaded(
        system: RailSystem.tra,
        originName: '台北',
        destName: '花蓮',
        date: '2026-06-30',
      );

      expect(loaded.delays, isEmpty);

      final updated = loaded.copyWith(delays: {trainNo: delayMinutes});
      expect(updated.delays[trainNo], equals(delayMinutes));
    },
  );

  test(
    'RailDelaysUpdated updates delays when state is RailTimetableLoaded',
    () async {
      final bloc = RailBloc();
      addTearDown(bloc.close);

      bloc.add(const RailDelaysUpdated({'110': 3}));
      await Future<void>.delayed(Duration.zero);

      expect(bloc.state, isA<RailInitial>());
    },
  );

  test(
    'a stale timetable request resolving after a newer one does not '
    'overwrite it',
    () async {
      final firstCompleter = Completer<List<ThsrTimetableItem>>();
      final secondCompleter = Completer<List<ThsrTimetableItem>>();
      final thsr = _ControlledThsrRepository([
        firstCompleter,
        secondCompleter,
      ]);
      final bloc = RailBloc(thsrRepository: thsr);
      addTearDown(bloc.close);

      const firstItem = ThsrTimetableItem(
        trainNo: '101',
        departureTime: '08:00',
        arrivalTime: '09:30',
        travelMinutes: 90,
        delayMinutes: 0,
        remark: '',
      );
      const secondItem = ThsrTimetableItem(
        trainNo: '201',
        departureTime: '10:00',
        arrivalTime: '11:30',
        travelMinutes: 90,
        delayMinutes: 0,
        remark: '',
      );

      RailTimetableRequested request(String date) => RailTimetableRequested(
        system: RailSystem.thsr,
        origin: const RailStationSelection(name: '南港', id: '0990'),
        destination: const RailStationSelection(name: '左營', id: '1070'),
        date: date,
      );

      bloc
        ..add(request('2026-07-10'))
        ..add(request('2026-07-11'));

      // The second, newer request resolves first...
      secondCompleter.complete([secondItem]);
      await pumpEventQueue();
      // ...then the stale first request resolves after it.
      firstCompleter.complete([firstItem]);
      await pumpEventQueue();

      final state = bloc.state;
      expect(state, isA<RailTimetableLoaded>());
      expect((state as RailTimetableLoaded).date, '2026-07-11');
      expect(state.thsrItems, [secondItem]);
    },
  );
}

class _ControlledThsrRepository extends ThsrRepository {
  _ControlledThsrRepository(this.completers);

  /// Each successive `timetable()` call consumes the next completer in
  /// order, so overlapping requests in a test can resolve out of order.
  final List<Completer<List<ThsrTimetableItem>>> completers;
  var _calls = 0;

  @override
  Future<List<ThsrTimetableItem>> timetable(
    String date,
    String originId,
    String destId,
  ) => completers[_calls++].future;
}

class _FakeThsrRepository extends ThsrRepository {
  _FakeThsrRepository({
    this.timetableResult = const [],
    this.error,
    this.fareResult,
  });

  final List<ThsrTimetableItem> timetableResult;
  final Error? error;
  final List<ThsrFare>? fareResult;
  final timetableCalls = <(String, String, String)>[];

  @override
  Future<List<ThsrFare>> fares(
    String date,
    String originId,
    String destId,
  ) async => fareResult ?? (throw StateError('no fare'));

  @override
  Future<List<ThsrTimetableItem>> timetable(
    String date,
    String originId,
    String destId,
  ) async {
    timetableCalls.add((date, originId, destId));
    if (error case final error?) throw error;
    return timetableResult;
  }
}

class _FakeTraRepository extends TraRepository {
  _FakeTraRepository({Stream<Map<String, int>>? delayStream})
    : _delayStream = delayStream ?? const Stream.empty();

  final Stream<Map<String, int>> _delayStream;
  final timetableCalls = <(String, String, String)>[];
  final delayCalls = <(String, String, String)>[];

  // The TRA list screen quotes no fare (it is per train class, not per O/D),
  // so the bloc must never call this — a throw keeps that pinned.
  @override
  Future<List<TraFare>> fares(String originId, String destId) async =>
      throw StateError('no fare');

  @override
  Future<List<TraTimetableItem>> timetable(
    String date,
    String originId,
    String destId,
  ) async {
    timetableCalls.add((date, originId, destId));
    return const [];
  }

  @override
  Stream<Map<String, int>> delay(
    String date,
    String originId,
    String destId,
  ) {
    delayCalls.add((date, originId, destId));
    return _delayStream;
  }
}
