import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:wheres_the_bus/data/models/bus_models.dart';
import 'package:wheres_the_bus/data/models/favorite.dart';
import 'package:wheres_the_bus/data/repositories/bus_repository.dart';
import 'package:wheres_the_bus/data/repositories/favorites_repository.dart';
import 'package:wheres_the_bus/features/bus/bloc/bus_stop_bloc.dart';
import 'package:wheres_the_bus/features/bus/view/bus_stop_detail_view.dart';
import 'package:wheres_the_bus/features/favorites/bloc/favorites_bloc.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';

import '../../support/helpers/i18n.dart';

void main() {
  testWidgets('the supplied bloc going away does not swap providers', (
    tester,
  ) async {
    final bloc = BusStopBloc(
      i18n: zhStrings,
      stopId: '',
      repository: _FakeRepository(),
    );
    addTearDown(bloc.close);

    // The detail header's bookmark button reads the favourites bloc; without
    // one the header renders an ErrorWidget and takeException() reports that
    // instead of the provider swap this test is actually watching for.
    final favorites = FavoritesBloc(
      _FakeFavoritesRepository(),
      ValueNotifier(true),
    );
    addTearDown(favorites.close);

    await tester.pumpWidget(_host(bloc, favorites));
    await tester.pump();

    // Same widget, same position, parameter gone — exactly the frame the home
    // map produces between dropping the group and the sheet finishing its exit.
    await tester.pumpWidget(_host(null, favorites));
    await tester.pump();

    expect(tester.takeException(), isNull);
  });
}

Widget _host(BusStopBloc? bloc, FavoritesBloc favorites) => MaterialApp(
  locale: const Locale('zh'),
  localizationsDelegates: AppI18n.localizationsDelegates,
  supportedLocales: AppI18n.supportedLocales,

  home: Scaffold(
    body: BlocProvider<FavoritesBloc>.value(
      value: favorites,
      child: BusStopDetailView(
        stopName: '台北車站',
        stopId: 'group-1',
        bloc: bloc,
      ),
    ),
  ),
);

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

class _FakeRepository implements BusRepository {
  @override
  Future<List<BusStationMember>> stationGroup(String groupUid) async => const [
    BusStationMember(
      stationUid: 'stop-1',
      stationId: 'sid-1',
      stationName: '台北車站',
      lat: 25,
      lon: 121,
    ),
  ];

  @override
  Stream<List<BusStopArrival>> stationEta(String city, String groupUid) async* {
    yield const [];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} not faked');
}
