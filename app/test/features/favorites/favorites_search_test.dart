import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:wheres_the_bus/data/models/favorite.dart';
import 'package:wheres_the_bus/data/repositories/favorites_repository.dart';
import 'package:wheres_the_bus/features/favorites/bloc/favorites_bloc.dart';
import 'package:wheres_the_bus/features/favorites/view/favorites_screen.dart';

import '../../support/helpers/i18n.dart';

const _route = Favorite(
  type: FavoriteType.busRoute,
  refId: '307',
  title: '307',
  subtitle: '台北車站 — 撫遠街',
);
const _stop = Favorite(
  type: FavoriteType.busStop,
  refId: 'taipei',
  title: '台北車站',
  subtitle: 'Taipei City',
  pinned: true,
  order: 1,
);
const _bike = Favorite(
  type: FavoriteType.bikeStation,
  refId: 'bike',
  title: 'YouBike 市政府',
  order: 2,
);

class _FavoritesRepository implements FavoritesRepository {
  _FavoritesRepository(List<Favorite> items) : _items = [...items];

  List<Favorite> _items;
  final _changes = StreamController<void>.broadcast();
  final savedOrders = <List<Favorite>>[];

  @override
  bool get isReady => true;

  @override
  List<Favorite> all() => List.unmodifiable(_items);

  @override
  Stream<void> changes() => _changes.stream;

  void replace(List<Favorite> items) {
    _items = [...items];
    _changes.add(null);
  }

  @override
  Future<void> remove(String id) async {
    replace(_items.where((item) => item.id != id).toList());
  }

  @override
  Future<void> setPinned(String id, {required bool pinned}) async {
    replace([
      for (final item in _items)
        if (item.id == id) item.copyWith(pinned: pinned) else item,
    ]);
  }

  @override
  Future<bool> toggle(Favorite favorite) async {
    if (_items.any((item) => item.id == favorite.id)) {
      await remove(favorite.id);
      return false;
    }
    replace([..._items, favorite]);
    return true;
  }

  @override
  Future<void> saveOrder(List<Favorite> ordered) async {
    savedOrders.add([...ordered]);
    replace(ordered);
  }

  Future<void> close() => _changes.close();

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} not faked');
}

Future<_FavoritesRepository> _pump(
  WidgetTester tester, {
  List<Favorite> items = const [_route, _stop, _bike],
}) async {
  final repo = _FavoritesRepository(items);
  final ready = ValueNotifier(true);
  final bloc = FavoritesBloc(repo, ready);
  addTearDown(() async {
    await bloc.close();
    ready.dispose();
    await repo.close();
  });
  await tester.pumpWidget(
    i18nApp(BlocProvider.value(value: bloc, child: const FavoritesScreen())),
  );
  await tester.pumpAndSettle();
  return repo;
}

Future<void> _search(WidgetTester tester, String query) async {
  await tester.enterText(find.byType(TextField), query);
  await tester.pumpAndSettle();
}

List<String> _visibleIds(WidgetTester tester) => tester
    .widgetList<Dismissible>(find.byType(Dismissible))
    .map((row) => (row.key! as ValueKey<String>).value)
    .toList();

void main() {
  testWidgets(
    'search matches titles and subtitles without changing saved order',
    (tester) async {
      final repo = await _pump(tester);
      await _search(tester, '  台北車站  ');
      expect(_visibleIds(tester), [
        'dismiss-${_route.id}',
        'dismiss-${_stop.id}',
      ]);
      expect(find.text(zhStrings.favoritesSummary(3, 1)), findsOneWidget);
      expect(find.byType(ReorderableDragStartListener), findsNothing);
      expect(find.byType(ReorderableListView), findsNothing);

      await _search(tester, '  TAIPEI  ');
      expect(_visibleIds(tester), ['dismiss-${_stop.id}']);
      await _search(tester, 'yOuBiKe');
      expect(_visibleIds(tester), ['dismiss-${_bike.id}']);
      await _search(tester, '307');
      expect(_visibleIds(tester), ['dismiss-${_route.id}']);
      expect(repo.all(), [_route, _stop, _bike]);
      expect(repo.savedOrders, isEmpty);
    },
  );

  testWidgets('clear and whitespace restore the full reorderable list', (
    tester,
  ) async {
    final repo = await _pump(tester);
    await _search(tester, 'YouBike');
    await tester.tap(find.byTooltip(zhStrings.commonClear));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '',
    );
    expect(_visibleIds(tester), [
      'dismiss-${_route.id}',
      'dismiss-${_stop.id}',
      'dismiss-${_bike.id}',
    ]);
    expect(find.byType(ReorderableDragStartListener), findsNWidgets(3));
    await _search(tester, '   ');
    expect(find.byType(ReorderableDragStartListener), findsNWidgets(3));
    expect(repo.savedOrders, isEmpty);
  });

  testWidgets('no matches differs from an empty collection and stays live', (
    tester,
  ) async {
    final repo = await _pump(tester);
    await _search(tester, '機場');
    expect(find.text(zhStrings.favoritesNoMatches), findsOneWidget);
    expect(find.text(zhStrings.favoritesNoMatchesHint), findsOneWidget);
    expect(find.text(zhStrings.favoritesEmpty), findsNothing);
    expect(find.byType(Dismissible), findsNothing);

    final airport = _route.copyWith(title: '機場公車');
    repo.replace([airport, _stop, _bike]);
    await tester.pumpAndSettle();
    expect(find.text('機場公車'), findsOneWidget);
    expect(find.text(zhStrings.favoritesNoMatches), findsNothing);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '機場',
    );
  });

  testWidgets(
    'filtered favorites can be pinned, removed and restored with undo',
    (tester) async {
      final repo = await _pump(tester);
      await _search(tester, '307');
      await tester.tap(find.widgetWithIcon(IconButton, Symbols.keep_rounded));
      await tester.pumpAndSettle();
      expect(repo.all().first.pinned, isTrue);
      expect(find.text(zhStrings.favoritesSummary(3, 2)), findsOneWidget);
      await tester.drag(
        find.byKey(ValueKey('dismiss-${_route.id}')),
        const Offset(-650, 0),
      );
      await tester.pumpAndSettle();
      expect(repo.all().map((item) => item.id), [_stop.id, _bike.id]);
      expect(find.text(zhStrings.favoritesNoMatches), findsOneWidget);
      await tester.tap(find.text(zhStrings.commonUndo));
      await tester.pumpAndSettle();
      expect(_visibleIds(tester), ['dismiss-${_route.id}']);
      expect(repo.all().last.pinned, isTrue);
    },
  );

  testWidgets('removing the final favorite leaves the query clearable', (
    tester,
  ) async {
    await _pump(tester, items: [_route]);
    await _search(tester, '307');
    await tester.drag(
      find.byKey(ValueKey('dismiss-${_route.id}')),
      const Offset(-650, 0),
    );
    await tester.pumpAndSettle();
    expect(find.text(zhStrings.favoritesEmpty), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    await tester.tap(find.byTooltip(zhStrings.commonClear));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('search and no-match copy fit a narrow screen with large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await _pump(tester);
    await _search(tester, '沒有這個收藏');
    expect(find.text(zhStrings.favoritesNoMatchesHint), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
