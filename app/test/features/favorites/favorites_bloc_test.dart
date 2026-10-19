import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:wheres_the_bus/data/models/favorite.dart';
import 'package:wheres_the_bus/data/repositories/favorites_repository.dart';
import 'package:wheres_the_bus/features/favorites/bloc/favorites_bloc.dart';
import 'package:wheres_the_bus/features/favorites/bloc/favorites_event.dart';
import 'package:wheres_the_bus/features/favorites/bloc/favorites_state.dart';
import 'package:wheres_the_bus/features/favorites/view/favorites_screen.dart';
import 'package:wheres_the_bus/features/favorites/widgets/favorite_tile.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';

import '../../support/helpers/i18n.dart';

// Subscribe before the action: Bloc events create the coalesce timer later,
// so elapsed wall time alone does not establish that the refresh was delivered.
Future<FavoritesState> _waitForState(
  FavoritesBloc bloc,
  bool Function(FavoritesState) matches,
) {
  if (matches(bloc.state)) return Future.value(bloc.state);
  return bloc.stream.firstWhere(matches).timeout(const Duration(seconds: 5));
}

class _SpyNotifier extends ValueNotifier<bool> {
  _SpyNotifier(super.value);

  int listeners = 0;

  @override
  void addListener(VoidCallback listener) {
    listeners++;
    super.addListener(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    listeners--;
    super.removeListener(listener);
  }
}

void main() {
  test('the readiness listener is dropped once ready', () async {
    final ready = _SpyNotifier(false);
    final bloc = FavoritesBloc(_FakeFavoritesRepository(), ready);
    expect(ready.listeners, 1);
    ready.value = true;
    expect(ready.listeners, 0);
    await bloc.close();
    ready.dispose();
  });

  test('closing before readiness drops the pending listener', () async {
    final ready = _SpyNotifier(false);
    final bloc = FavoritesBloc(_FakeFavoritesRepository(), ready);
    await bloc.close();
    expect(ready.listeners, 0);
    ready.dispose();
  });

  test(
    'readiness starts once and closing removes the pending listener',
    () async {
      final ready = ValueNotifier(false);
      final repo = _FakeFavoritesRepository(items: [_favorite('pending')]);
      final bloc = FavoritesBloc(repo, ready);
      expect(bloc.state.items, isEmpty);
      final loaded = _waitForState(
        bloc,
        (state) => state.contains('busStop:pending'),
      );
      ready.value = true;
      await loaded;
      expect(bloc.state.items.single.refId, 'pending');
      ready
        ..value = false
        ..value = true;
      await bloc.close();
      expect(bloc.state.items, hasLength(1));
      final pending = FavoritesBloc(repo, ready..value = false);
      await pending.close();
      ready
        ..value = true
        ..dispose();
    },
  );

  for (final reduced in [false, true]) {
    testWidgets(
      'favorites empty, pin, reorder, remove and undo (reduced=$reduced)',
      (tester) async {
        final repo = _FakeFavoritesRepository();
        final bloc = FavoritesBloc(repo, ValueNotifier(true));
        addTearDown(bloc.close);
        await tester.pumpWidget(
          i18nApp(
            BlocProvider.value(
              value: bloc,
              child: MediaQuery(
                data: MediaQueryData(disableAnimations: reduced),
                child: const FavoritesScreen(),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text(zhStrings.favoritesEmpty), findsOneWidget);
        await repo.add(_favorite('first').copyWith(subtitle: '台北'));
        await repo.add(_favorite('second').copyWith(order: 1));
        await tester.pump(const Duration(milliseconds: 40));
        await tester.pumpAndSettle();
        expect(find.text('first'), findsOneWidget);
        expect(find.text('台北'), findsOneWidget);
        await tester.tap(find.byType(IconButton).first);
        await tester.pump(const Duration(milliseconds: 40));
        await tester.pumpAndSettle();
        expect(bloc.state.pinned.single.refId, 'first');
        final pinned = tester.widget<Icon>(
          find.byIcon(Symbols.keep_rounded).first,
        );
        expect(pinned.fill, 1);
        await tester.tap(find.byType(IconButton).first);
        await tester.pump(const Duration(milliseconds: 40));
        await tester.pumpAndSettle();
        expect(bloc.state.pinned, isEmpty);
        final handle = tester.getCenter(
          find.byIcon(Symbols.drag_handle_rounded).last,
        );
        final target = tester.getRect(
          find.byKey(const ValueKey('dismiss-busStop:first')),
        );
        final drag = await tester.startGesture(handle);
        await tester.pump(const Duration(milliseconds: 600));
        await drag.moveBy(Offset(0, -target.height));
        await tester.pump(const Duration(milliseconds: 300));
        await drag.up();
        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 40));
        await tester.pumpAndSettle();
        expect(repo.reorders, [
          ['second', 'first'],
        ], reason: 'handle=$handle target=$target');
        expect(bloc.state.items.map((f) => f.refId), ['second', 'first']);
        await tester.drag(
          find.byKey(const ValueKey('dismiss-busStop:first')),
          const Offset(-650, 0),
        );
        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 40));
        await tester.pumpAndSettle();
        expect(bloc.state.items.map((f) => f.refId), ['second']);
        await tester.tap(find.text(zhStrings.commonUndo));
        await tester.pump(const Duration(milliseconds: 40));
        await tester.pumpAndSettle();
        expect(bloc.state.items.map((f) => f.refId), ['second', 'first']);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets('favorite tiles open every transport destination', (
    tester,
  ) async {
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => Scaffold(
            body: Column(
              children: [
                for (final type in FavoriteType.values)
                  FavoriteTile(
                    fav: Favorite(
                      type: type,
                      refId: 'ref-${type.name}',
                      title: type.name,
                      subtitle: type == FavoriteType.railTrain ? '高鐵' : '',
                    ),
                  ),
              ],
            ),
          ),
        ),
        for (final path in [
          '/bus/stop',
          '/bus/route/:subRouteUid',
          '/metro/station/:id',
          '/rail',
          '/rail/train/:trainNo',
          '/bike/station',
        ])
          GoRoute(
            path: path,
            builder: (_, state) => Scaffold(body: Text(state.uri.toString())),
          ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      MaterialApp.router(
        routerConfig: router,
        locale: const Locale('zh'),
        localizationsDelegates: AppI18n.localizationsDelegates,
        supportedLocales: AppI18n.supportedLocales,
      ),
    );
    await tester.pumpAndSettle();
    for (final type in FavoriteType.values) {
      await tester.tap(find.text(type.name));
      await tester.pumpAndSettle();
      final uri = router.state.uri;
      final expectedPath = switch (type) {
        FavoriteType.busStop => '/bus/stop',
        FavoriteType.busRoute => '/bus/route/ref-busRoute',
        FavoriteType.metroStation => '/metro/station/ref-metroStation',
        FavoriteType.railStation => '/rail',
        FavoriteType.railTrain => '/rail/train/ref-railTrain',
        FavoriteType.bikeStation => '/bike/station',
      };
      final expectedQuery = switch (type) {
        FavoriteType.busStop => {
          'name': 'busStop',
          'id': 'ref-busStop',
          'city': '',
        },
        FavoriteType.railStation => {
          'sys': 'tra',
          'from': 'railStation',
          'fromId': 'ref-railStation',
        },
        FavoriteType.railTrain => {'sys': 'thsr'},
        FavoriteType.bikeStation => {'uid': 'ref-bikeStation'},
        _ => <String, String>{},
      };
      expect(uri.path, expectedPath);
      expect(uri.queryParameters, expectedQuery);
      router.pop();
      await tester.pumpAndSettle();
    }
    await tester.pumpWidget(const SizedBox());
  });

  test('refresh loads repository items when ready', () async {
    final repo = _FakeFavoritesRepository(items: [_favorite('stop-1')]);
    final bloc = FavoritesBloc(repo, ValueNotifier(true));
    addTearDown(bloc.close);

    await _waitForState(
      bloc,
      (state) => state.contains('busStop:stop-1'),
    );

    expect(bloc.state.items, hasLength(1));
  });

  test('toggle changes the collection', () async {
    final repo = _FakeFavoritesRepository();
    final bloc = FavoritesBloc(repo, ValueNotifier(true));
    addTearDown(bloc.close);

    final toggled = _waitForState(
      bloc,
      (state) => state.contains('busStop:stop-1'),
    );
    bloc.add(FavoriteToggled(_favorite('stop-1')));
    await toggled;

    expect(bloc.state.contains('busStop:stop-1'), isTrue);
  });

  test('remove deletes an item', () async {
    final repo = _FakeFavoritesRepository(items: [_favorite('stop-1')]);
    final bloc = FavoritesBloc(repo, ValueNotifier(true));
    addTearDown(bloc.close);

    await _waitForState(
      bloc,
      (state) => state.contains('busStop:stop-1'),
    );
    final removed = _waitForState(
      bloc,
      (state) => !state.contains('busStop:stop-1'),
    );
    bloc.add(const FavoriteRemoved('busStop:stop-1'));
    await removed;

    expect(bloc.state.contains('busStop:stop-1'), isFalse);
  });

  test('pin changed updates item pinned state', () async {
    final repo = _FakeFavoritesRepository(items: [_favorite('stop-1')]);
    final bloc = FavoritesBloc(repo, ValueNotifier(true));
    addTearDown(bloc.close);

    await _waitForState(
      bloc,
      (state) => state.contains('busStop:stop-1'),
    );
    final pinned = _waitForState(
      bloc,
      (state) => state.pinned.any((item) => item.id == 'busStop:stop-1'),
    );
    bloc.add(const FavoritePinChanged('busStop:stop-1', pinned: true));
    await pinned;

    expect(bloc.state.pinned, hasLength(1));
  });

  test('reorder of N items produces a single coalesced refresh', () async {
    final repo = _FakeFavoritesRepository(
      items: [_favorite('a'), _favorite('b'), _favorite('c'), _favorite('d')],
    );
    final bloc = FavoritesBloc(repo, ValueNotifier(true));
    addTearDown(bloc.close);

    await _waitForState(bloc, (state) => state.items.length == 4);
    // Drop the initial refresh and count only reorder-driven emissions.
    var refreshes = 0;
    final sub = bloc.stream.listen((_) => refreshes++);
    addTearDown(sub.cancel);

    final reordered = [
      repo.all()[3],
      repo.all()[2],
      repo.all()[1],
      repo.all()[0],
    ];
    final reorderedState = _waitForState(
      bloc,
      (state) => state.items.map((item) => item.refId).join(',') == 'd,c,b,a',
    );
    bloc.add(FavoritesReordered(reordered));
    await reorderedState;
    // Closing drains the state stream before checking the emission count.
    await bloc.close();

    // 4 box writes -> 1 coalesced refresh, not 4.
    expect(refreshes, 1);
    expect(bloc.state.items.map((item) => item.refId), ['d', 'c', 'b', 'a']);
    expect(repo.all().map((f) => f.refId).toList(), ['d', 'c', 'b', 'a']);
  });
}

Favorite _favorite(String refId) => Favorite(
  type: FavoriteType.busStop,
  refId: refId,
  title: refId,
);

class _FakeFavoritesRepository implements FavoritesRepository {
  _FakeFavoritesRepository({List<Favorite> items = const []})
    : _items = {
        for (final (i, item) in items.indexed) item.id: item.copyWith(order: i),
      };

  final Map<String, Favorite> _items;
  final reorders = <List<String>>[];
  final _events = StreamController<BoxEvent>.broadcast();
  final _changes = StreamController<void>.broadcast();
  Timer? _coalesceTimer;

  void _notify(String id, {bool deleted = false}) {
    _events.add(BoxEvent(id, _items[id]?.toMap(), deleted));
    // Mirror the real repository: collapse a burst of writes into one signal.
    _coalesceTimer?.cancel();
    _coalesceTimer = Timer(const Duration(milliseconds: 16), () {
      _coalesceTimer = null;
      _changes.add(null);
    });
  }

  @override
  bool get isReady => true;

  @override
  Stream<BoxEvent> watch() => _events.stream;

  @override
  Stream<void> changes() => _changes.stream;

  @override
  List<Favorite> all() =>
      _items.values.toList()..sort((a, b) => a.order.compareTo(b.order));

  @override
  List<Favorite> pinned() => all().where((f) => f.pinned).toList();

  @override
  List<Favorite> ofType(FavoriteType type) =>
      all().where((f) => f.type == type).toList();

  @override
  bool isFavorite(String id) => _items.containsKey(id);

  @override
  Future<void> add(Favorite fav) async {
    _items[fav.id] = fav;
    _notify(fav.id);
  }

  @override
  Future<void> remove(String id) async {
    _items.remove(id);
    _notify(id, deleted: true);
  }

  @override
  Future<bool> toggle(Favorite fav) async {
    if (_items.containsKey(fav.id)) {
      await remove(fav.id);
      return false;
    }
    await add(fav);
    return true;
  }

  @override
  Future<void> setPinned(String id, {required bool pinned}) async {
    final current = _items[id];
    if (current == null) return;
    _items[id] = current.copyWith(pinned: pinned);
    _notify(id);
  }

  @override
  Future<void> saveOrder(List<Favorite> ordered) async {
    reorders.add(ordered.map((f) => f.refId).toList());
    for (final (index, favorite) in ordered.indexed) {
      _items[favorite.id] = favorite.copyWith(order: index);
      _notify(favorite.id);
    }
  }

  @override
  Future<void> migrateLegacy() async {}
}
