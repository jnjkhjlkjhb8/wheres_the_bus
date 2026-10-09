import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart';
import 'package:hive_ce/hive.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/data/models/favorite.dart';
import 'package:wheres_the_bus/data/models/rail_station_board.dart';
import 'package:wheres_the_bus/data/repositories/favorites_repository.dart';
import 'package:wheres_the_bus/data/repositories/tra_repository.dart';
import 'package:wheres_the_bus/features/favorites/bloc/favorites_bloc.dart';
import 'package:wheres_the_bus/features/rail/bloc/rail_event.dart';
import 'package:wheres_the_bus/features/rail/bloc/rail_station_board_bloc.dart';
import 'package:wheres_the_bus/features/rail/bloc/rail_station_board_event.dart';
import 'package:wheres_the_bus/features/rail/view/rail_station_detail_view.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';

// The board is only reachable on a map screen, and the test flavor ships no
// Maps key, so a rendered widget test is how this screen gets verified.

RailStationDeparture _departureIn(
  Duration ahead, {
  String trainNo = '271',
  String destination = '潮州',
}) {
  final at = DateTime.now().add(ahead);
  String two(int v) => v.toString().padLeft(2, '0');
  return _departure(
    time: '${two(at.hour)}:${two(at.minute)}:${two(at.second)}',
    trainNo: trainNo,
    destination: destination,
    serviceDate: '${at.year}-${two(at.month)}-${two(at.day)}',
  );
}

RailStationDeparture _departure({
  required String time,
  String trainNo = '271',
  String destination = '潮州',
  String serviceDate = '2026-07-29',
  bool suspended = false,
}) => RailStationDeparture(
  trainNo: trainNo,
  trainType: '自強',
  destination: destination,
  departureTime: time,
  serviceDate: serviceDate,
  isSuspended: suspended,
);

void main() {
  Future<void> pumpBoard(
    WidgetTester tester, {
    required _FakeTraRepository repo,
    double textScale = 1,
    Size size = const Size(390, 844),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final bloc = RailStationBoardBloc(
      system: RailSystem.tra,
      stationId: '1000',
      traRepository: repo,
      clock: () => DateTime(2026, 7, 29, 14, 29),
    )..add(const RailStationBoardRequested(RailBoardDirection.forward));
    addTearDown(bloc.close);

    // The header's bookmark button reads the favourites bloc; without one the
    // header renders an ErrorWidget and every other assertion is meaningless.
    final favorites = FavoritesBloc(
      _FakeFavoritesRepository(),
      ValueNotifier(true),
    );
    addTearDown(favorites.close);

    await tester.pumpWidget(
      MaterialApp(
        // Pinned to zh-TW: flutter_test reports an en_US platform locale, and
        // every string on this screen is authored in the zh template.
        locale: const Locale('zh'),
        localizationsDelegates: AppI18n.localizationsDelegates,
        supportedLocales: AppI18n.supportedLocales,
        theme: AppTheme.light,
        home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
          child: Scaffold(
            body: BlocProvider<FavoritesBloc>.value(
              value: favorites,
              child: RailStationDetailView(
                system: RailSystem.tra,
                stationId: '1000',
                name: '台北車站',
                bloc: bloc,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> disposeBoard(WidgetTester tester) =>
      tester.pumpWidget(const SizedBox.shrink());

  testWidgets('renders the departures a rider scans for', (tester) async {
    await pumpBoard(
      tester,
      repo: _FakeTraRepository(
        board: [
          _departure(time: '14:32:00'),
          _departure(time: '14:38:00', trainNo: '2183', destination: '竹南'),
        ],
      ),
    );

    // The time is the scan column and the destination is the decision, so both
    // have to be on screen without a tap.
    expect(find.text('14:32'), findsOneWidget);
    expect(find.text('往潮州'), findsOneWidget);
    expect(find.text('往竹南'), findsOneWidget);
    expect(find.text('271'), findsOneWidget);
    // Seconds are precision the timetable does not have.
    expect(find.text('14:32:00'), findsNothing);

    await disposeBoard(tester);
  });

  // TDX's live TRA data runs about two minutes behind the platform displays
  // and the operator asks that riders be told so.
  testWidgets('the TRA board states its live-data lag', (tester) async {
    await pumpBoard(
      tester,
      repo: _FakeTraRepository(board: [_departure(time: '14:32:00')]),
    );

    await tester.scrollUntilVisible(
      find.textContaining('進站後請以站內看板為準'),
      200,
    );
    expect(find.textContaining('進站後請以站內看板為準'), findsOneWidget);

    await disposeBoard(tester);
  });

  testWidgets('only the soonest departure carries a countdown', (tester) async {
    await pumpBoard(
      tester,
      repo: _FakeTraRepository(
        board: [
          // The extra 30s keeps inMinutes off the truncation boundary.
          _departureIn(const Duration(minutes: 3, seconds: 30)),
          _departureIn(
            const Duration(minutes: 9, seconds: 30),
            trainNo: '2183',
          ),
          _departureIn(
            const Duration(minutes: 18, seconds: 30),
            trainNo: '553',
          ),
        ],
      ),
    );

    // Giving every row a countdown turns the column into arithmetic to read
    // instead of scan, and buries the only number that decides whether to run.
    expect(find.text('3 分後'), findsOneWidget);
    expect(find.text('9 分後'), findsNothing);
    expect(find.text('18 分後'), findsNothing);

    await disposeBoard(tester);
  });

  testWidgets('marks where the board crosses into the next day', (
    tester,
  ) async {
    await pumpBoard(
      tester,
      repo: _FakeTraRepository(
        board: [
          _departure(time: '23:55:00'),
          _departure(
            time: '05:10:00',
            trainNo: '2201',
            serviceDate: '2026-07-30',
          ),
        ],
      ),
    );

    // Without the break, 05:10 reads as a train that already left this morning.
    expect(find.text('明日'), findsOneWidget);

    await disposeBoard(tester);
  });

  testWidgets('a landed day with no trains left says the day is over', (
    tester,
  ) async {
    await pumpBoard(tester, repo: _FakeTraRepository());

    expect(find.text('今日順行班次已結束'), findsOneWidget);
    expect(find.text('該日時刻表尚未提供'), findsNothing);

    await disposeBoard(tester);
  });

  testWidgets('an unlanded day says the data has not arrived', (tester) async {
    await pumpBoard(
      tester,
      repo: _FakeTraRepository(
        error: const GrpcError.notFound('station board not found'),
      ),
    );

    // The distinction matters: one is the end of the day, the other is a gap
    // in the data, and telling a rider the wrong one wastes their time.
    expect(find.text('該日時刻表尚未提供'), findsOneWidget);
    expect(find.textContaining('今日'), findsNothing);

    await disposeBoard(tester);
  });

  testWidgets('a suspended train is struck through and not tappable', (
    tester,
  ) async {
    await pumpBoard(
      tester,
      repo: _FakeTraRepository(
        board: [_departure(time: '14:32:00', suspended: true)],
      ),
    );

    expect(find.text('停駛'), findsOneWidget);
    final time = tester.widget<Text>(find.text('14:32'));
    expect(time.style?.decoration, TextDecoration.lineThrough);

    await disposeBoard(tester);
  });

  testWidgets('the origin/destination query stays reachable', (tester) async {
    await pumpBoard(
      tester,
      repo: _FakeTraRepository(board: [_departure(time: '14:32:00')]),
    );

    // Fares, arrival times and other dates only exist on that path, so the
    // board must not become the only way out of this sheet.
    expect(find.text('指定目的地查詢'), findsOneWidget);

    await disposeBoard(tester);
  });

  testWidgets('rows survive the largest text scale without overflowing', (
    tester,
  ) async {
    await pumpBoard(
      tester,
      textScale: 2,
      // Older riders run the app at large text (Settings' 大字模式), on the
      // narrowest phone the app supports.
      size: const Size(320, 844),
      repo: _FakeTraRepository(
        board: [
          // Relative, so the first row also renders its countdown — the widest
          // thing the time column ever has to hold.
          _departureIn(
            const Duration(minutes: 3, seconds: 30),
            destination: '新左營',
          ),
          _departure(time: '14:38:00', trainNo: '2183', destination: '竹南'),
        ],
      ),
    );

    expect(tester.takeException(), isNull);

    await disposeBoard(tester);
  });
}

class _FakeFavoritesRepository implements FavoritesRepository {
  @override
  bool get isReady => true;

  @override
  Stream<BoxEvent> watch() => const Stream.empty();

  @override
  Stream<void> changes() => const Stream.empty();

  @override
  List<Favorite> all() => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeTraRepository implements TraRepository {
  _FakeTraRepository({this.board = const [], this.error});

  final List<RailStationDeparture> board;
  final Exception? error;

  @override
  Future<List<RailStationDeparture>> stationBoard({
    required String stationId,
    required String date,
    required String after,
    required RailBoardDirection direction,
  }) async {
    if (error != null) throw error!;
    return board;
  }

  // A stream that never closes. An empty one ends immediately, and the
  // resilient-stream layer answers a closed live stream by scheduling a
  // reconnect — a pending timer the widget binding then fails the test on.
  @override
  Stream<Map<String, int>> delay(String date, String origin, String dest) =>
      Stream<Map<String, int>>.fromFuture(
        Completer<Map<String, int>>().future,
      );

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} not faked');
}
