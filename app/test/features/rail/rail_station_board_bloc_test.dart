import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart';
import 'package:wheres_the_bus/core/errors/app_error.dart';
import 'package:wheres_the_bus/data/models/rail_station_board.dart';
import 'package:wheres_the_bus/data/repositories/thsr_repository.dart';
import 'package:wheres_the_bus/data/repositories/tra_repository.dart';
import 'package:wheres_the_bus/features/rail/bloc/rail_event.dart';
import 'package:wheres_the_bus/features/rail/bloc/rail_station_board_bloc.dart';
import 'package:wheres_the_bus/features/rail/bloc/rail_station_board_event.dart';
import 'package:wheres_the_bus/features/rail/bloc/rail_station_board_state.dart';

RailStationDeparture _departure(String time, {String trainNo = '271'}) =>
    RailStationDeparture(
      trainNo: trainNo,
      trainType: '自強',
      destination: '潮州',
      departureTime: time,
      serviceDate: '2026-07-29',
    );

void main() {
  final now = DateTime(2026, 7, 29, 14, 29, 30);

  RailStationBoardBloc bloc(_FakeTraRepository tra) => RailStationBoardBloc(
    system: RailSystem.tra,
    stationId: '1000',
    traRepository: tra,
    clock: () => now,
  );

  test("sends the rider's own date and clock as the window bound", () async {
    final repo = _FakeTraRepository(board: [_departure('14:32:00')]);
    final b = bloc(repo);
    addTearDown(b.close);

    b.add(const RailStationBoardRequested(RailBoardDirection.forward));
    await b.stream.firstWhere((s) => s is RailStationBoardLoaded);

    // The router runs in UTC, so a server-side "now" would cut the board eight
    // hours off. The device clock is the only correct source for the bound.
    expect(repo.lastDate, '2026-07-29');
    expect(repo.lastAfter, '14:29:30');
    expect(repo.lastDirection, RailBoardDirection.forward);
  });

  test('an empty board is loaded, not a failure', () async {
    // The service day is landed and its trains have gone. That is an answer —
    // rendering it as an error would tell the rider the app is broken.
    final b = bloc(_FakeTraRepository());
    addTearDown(b.close);

    b.add(const RailStationBoardRequested(RailBoardDirection.forward));
    final state = await b.stream.firstWhere(
      (s) => s is! RailStationBoardLoading,
    );

    expect(state, isA<RailStationBoardLoaded>());
    expect((state as RailStationBoardLoaded).departures, isEmpty);
  });

  test('a NotFound day surfaces as a failure the view can name', () async {
    final b = bloc(
      _FakeTraRepository(
        error: const GrpcError.notFound('timetable not found'),
      ),
    );
    addTearDown(b.close);

    b.add(const RailStationBoardRequested(RailBoardDirection.forward));
    final state = await b.stream.firstWhere(
      (s) => s is RailStationBoardFailure,
    );

    expect((state as RailStationBoardFailure).error, isA<NotFoundError>());
    // The segment must stay where the rider put it even when the load fails.
    expect(state.direction, RailBoardDirection.forward);
  });

  test('switching direction reloads and keeps it in state', () async {
    final repo = _FakeTraRepository(board: [_departure('14:32:00')]);
    final b = bloc(repo);
    addTearDown(b.close);

    b.add(const RailStationBoardRequested(RailBoardDirection.reverse));
    final state = await b.stream.firstWhere((s) => s is RailStationBoardLoaded);

    expect(state.direction, RailBoardDirection.reverse);
    expect(repo.lastDirection, RailBoardDirection.reverse);
  });

  test('delays already in hand survive a direction switch', () async {
    // The delay stream is system-wide and subscribed once, so a switch that
    // dropped the map would blank the 誤點 column until the next frame — which
    // may be 30s away.
    final repo = _FakeTraRepository(board: [_departure('14:32:00')])
      ..delayStream = Stream.value(const {'271': 5});
    final b = bloc(repo);
    addTearDown(b.close);

    b.add(const RailStationBoardRequested(RailBoardDirection.forward));
    await b.stream.firstWhere(
      (s) => s is RailStationBoardLoaded && s.delays.isNotEmpty,
    );

    b.add(const RailStationBoardRequested(RailBoardDirection.reverse));
    final after = await b.stream.firstWhere(
      (s) =>
          s is RailStationBoardLoaded &&
          s.direction == RailBoardDirection.reverse,
    );

    expect((after as RailStationBoardLoaded).delays, {'271': 5});
  });

  test('THSR opens no delay subscription', () async {
    // THSR publishes no delay board; subscribing to the TRA one would apply
    // TRA train numbers onto THSR rows.
    final tra = _FakeTraRepository()
      ..delayStream = Stream.value(const {'271': 5});
    final b = RailStationBoardBloc(
      system: RailSystem.thsr,
      stationId: '1000',
      traRepository: tra,
      thsrRepository: _FakeThsrRepository(board: [_departure('14:36:00')]),
      clock: () => now,
    );
    addTearDown(b.close);

    b.add(const RailStationBoardRequested(RailBoardDirection.forward));
    await b.stream.firstWhere((s) => s is RailStationBoardLoaded);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(tra.delaySubscribed, isFalse);
  });
}

class _FakeTraRepository implements TraRepository {
  _FakeTraRepository({this.board = const [], this.error});

  final List<RailStationDeparture> board;
  final Exception? error;

  Stream<Map<String, int>> delayStream = const Stream.empty();
  bool delaySubscribed = false;

  String? lastDate;
  String? lastAfter;
  RailBoardDirection? lastDirection;

  @override
  Future<List<RailStationDeparture>> stationBoard({
    required String stationId,
    required String date,
    required String after,
    required RailBoardDirection direction,
  }) async {
    lastDate = date;
    lastAfter = after;
    lastDirection = direction;
    if (error != null) throw error!;
    return board;
  }

  @override
  Stream<Map<String, int>> delay(String date, String origin, String dest) {
    delaySubscribed = true;
    return delayStream;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} not faked');
}

class _FakeThsrRepository implements ThsrRepository {
  _FakeThsrRepository({this.board = const []});

  final List<RailStationDeparture> board;

  @override
  Future<List<RailStationDeparture>> stationBoard({
    required String stationId,
    required String date,
    required String after,
    required RailBoardDirection direction,
  }) async => board;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} not faked');
}
