import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/data/models/rail_station_board.dart';
import 'package:wheres_the_bus/data/repositories/thsr_repository.dart';
import 'package:wheres_the_bus/data/repositories/tra_repository.dart';
import 'package:wheres_the_bus/features/favorites/bloc/favorites_bloc.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';

import 'metro_station_harness.dart';

class BoardTraRepository implements TraRepository {
  BoardTraRepository({this.board = const [], this.error, this.gate});

  /// When set, a board request waits for it, so a test can look at the sheet
  /// while the request is in flight.
  Future<void>? gate;

  final List<RailStationDeparture> board;
  final Exception? error;

  @override
  Future<List<RailStationDeparture>> stationBoard({
    required String stationId,
    required String date,
    required String after,
    required RailBoardDirection direction,
  }) async {
    await gate;
    if (error != null) throw error!;
    return board;
  }

  // Never closes: a closed live stream makes the resilient layer schedule a
  // reconnect timer that fails the widget test.
  @override
  Stream<Map<String, int>> delay(String date, String origin, String dest) =>
      Stream<Map<String, int>>.fromFuture(
        Completer<Map<String, int>>().future,
      );

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} not faked');
}

class BoardThsrRepository implements ThsrRepository {
  BoardThsrRepository({this.board = const []});

  final List<RailStationDeparture> board;

  @override
  Future<List<RailStationDeparture>> stationBoard({
    required String stationId,
    required String date,
    required RailBoardDirection direction,
    required String after,
  }) async => board;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Pumps [child] in a zh-TW app with a favourites bloc, the way the rail
/// sheets are hosted.
Future<void> pumpRailHost(
  WidgetTester tester,
  Widget child, {
  Size size = const Size(390, 844),
  double textScale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final favorites = FavoritesBloc(
    EmptyFavoritesRepository(),
    ValueNotifier(true),
  );
  addTearDown(favorites.close);
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppI18n.localizationsDelegates,
      supportedLocales: AppI18n.supportedLocales,
      theme: AppTheme.light,
      home: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
        child: Scaffold(
          body: BlocProvider<FavoritesBloc>.value(
            value: favorites,
            child: child,
          ),
        ),
      ),
    ),
  );
}
