import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:wheres_the_bus/data/models/favorite.dart';
import 'package:wheres_the_bus/data/repositories/favorites_repository.dart';
import 'package:wheres_the_bus/features/favorites/bloc/favorites_bloc.dart';
import 'package:wheres_the_bus/features/favorites/bloc/favorites_event.dart';

// Long enough to outlast the fake's coalesce window and let the queued
// FavoritesRefreshed event drain.
Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 40));

void main() {
  test('refresh loads repository items when ready', () async {
    final repo = _FakeFavoritesRepository(items: [_favorite('stop-1')]);
    final bloc = FavoritesBloc(repo, ValueNotifier(true));
    addTearDown(bloc.close);

    await _settle();

    expect(bloc.state.items, hasLength(1));
  });

  test('toggle changes the collection', () async {
    final repo = _FakeFavoritesRepository();
    final bloc = FavoritesBloc(repo, ValueNotifier(true));
    addTearDown(bloc.close);

    bloc.add(FavoriteToggled(_favorite('stop-1')));
    await _settle();

    expect(bloc.state.contains('busStop:stop-1'), isTrue);
  });

  test('remove deletes an item', () async {
    final repo = _FakeFavoritesRepository(items: [_favorite('stop-1')]);
    final bloc = FavoritesBloc(repo, ValueNotifier(true));
    addTearDown(bloc.close);

    await _settle();
    bloc.add(const FavoriteRemoved('busStop:stop-1'));
    await _settle();

    expect(bloc.state.contains('busStop:stop-1'), isFalse);
  });

  test('pin changed updates item pinned state', () async {
    final repo = _FakeFavoritesRepository(items: [_favorite('stop-1')]);
    final bloc = FavoritesBloc(repo, ValueNotifier(true));
    addTearDown(bloc.close);

    await _settle();
    bloc.add(const FavoritePinChanged('busStop:stop-1', pinned: true));
    await _settle();

    expect(bloc.state.pinned, hasLength(1));
  });

  test('reorder of N items produces a single coalesced refresh', () async {
    final repo = _FakeFavoritesRepository(
      items: [_favorite('a'), _favorite('b'), _favorite('c'), _favorite('d')],
    );
    final bloc = FavoritesBloc(repo, ValueNotifier(true));
    addTearDown(bloc.close);

    await _settle();
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
    bloc.add(FavoritesReordered(reordered));
    await _settle();

    // 4 box writes -> 1 coalesced refresh, not 4.
    expect(refreshes, 1);
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
    for (final (index, favorite) in ordered.indexed) {
      _items[favorite.id] = favorite.copyWith(order: index);
      _notify(favorite.id);
    }
  }

  @override
  Future<void> migrateLegacy() async {}
}
