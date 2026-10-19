import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:wheres_the_bus/data/models/favorite.dart';
import 'package:wheres_the_bus/data/repositories/favorites_repository.dart';

Favorite _favorite(String refId) =>
    Favorite(type: FavoriteType.busStop, refId: refId, title: refId);

// Outlasts the repository's 16ms coalesce window.
Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 40));

void main() {
  final repo = FavoritesRepository.instance;

  setUpAll(() async {
    Hive.init('./.dart_tool/hive_test_favorites');
    await Hive.openBox<dynamic>('favorites');
  });

  setUp(() async {
    // Wipe data between tests; the next repo write nulls the singleton's cache.
    await Hive.box<dynamic>('favorites').clear();
    await repo.add(_favorite('__seed__'));
    await repo.remove('busStop:__seed__');
  });

  test(
    'toggle, pinning and duplicate adds preserve identity and timestamps',
    () async {
      const saved = Favorite(
        type: FavoriteType.busStop,
        refId: 'saved',
        title: 'Saved',
        createdAt: 1234,
      );
      expect(repo.isFavorite(saved.id), isFalse);
      expect(await repo.toggle(saved), isTrue);
      expect(repo.isFavorite(saved.id), isTrue);
      expect(repo.all().single.createdAt, 1234);
      await repo.add(saved.copyWith(title: 'Duplicate'));
      expect(repo.all().single.title, 'Saved');
      await repo.setPinned(saved.id, pinned: true);
      expect(repo.pinned().single.id, saved.id);
      await repo.setPinned('missing', pinned: true);
      await repo.setPinned(saved.id, pinned: false);
      expect(repo.pinned(), isEmpty);
      expect(await repo.toggle(saved), isFalse);
      expect(repo.isFavorite(saved.id), isFalse);
      await Hive.box<dynamic>('favorites').put('invalid', 4);
      await repo.setPinned('invalid', pinned: true);
      expect(Hive.box<dynamic>('favorites').get('invalid'), 4);
    },
  );

  test('add appends after the greatest saved order', () async {
    await repo.add(_favorite('first'));
    await repo.add(_favorite('second'));
    await repo.saveOrder(repo.all().reversed.toList());
    await repo.add(_favorite('third'));
    expect(repo.all().map((f) => f.refId), ['second', 'first', 'third']);
    expect(repo.all().last.order, 2);
    expect(repo.all().last.createdAt, greaterThan(0));
  });

  test(
    'saveOrder emits exactly one coalesced refresh for an N-item reorder',
    () async {
      await repo.add(_favorite('a'));
      await repo.add(_favorite('b'));
      await repo.add(_favorite('c'));
      await repo.add(_favorite('d'));
      await _settle();

      // Start counting only after the seed writes have flushed.
      var refreshes = 0;
      final sub = repo.changes().listen((_) => refreshes++);
      addTearDown(sub.cancel);

      final current = repo.all();
      await repo.saveOrder(current.reversed.toList());
      await _settle();

      // Four box writes collapse into a single downstream refresh.
      expect(refreshes, 1);
      expect(repo.all().map((f) => f.refId).toList(), ['d', 'c', 'b', 'a']);
    },
  );

  test(
    'all() returns cached-but-correct data across reads and writes',
    () async {
      await repo.add(_favorite('a'));
      await repo.add(_favorite('b'));

      final first = repo.all();
      final second = repo.all();
      // No write between reads: same cached instance is reused (no
      // rescan+sort).
      expect(identical(first, second), isTrue);
      expect(first.map((f) => f.refId).toList(), ['a', 'b']);

      // A write invalidates the cache; the next read reflects it correctly.
      await repo.add(_favorite('c'));
      final third = repo.all();
      expect(identical(third, first), isFalse);
      expect(third.map((f) => f.refId).toList(), ['a', 'b', 'c']);
    },
  );

  test('a write is signalled only after the coalesce window', () async {
    await repo.add(_favorite('a'));
    await _settle();
    var refreshes = 0;
    final sub = repo.changes().listen((_) => refreshes++);
    addTearDown(sub.cancel);

    await repo.add(_favorite('b'));
    // Shorter than the 16ms window, so a debounce that fires at once would
    // already have signalled.
    await Future<void>.delayed(const Duration(milliseconds: 4));
    expect(refreshes, 0);

    await _settle();
    expect(refreshes, 1);
  });

  test('the box watcher is released when the last listener leaves', () async {
    await repo.add(_favorite('a'));
    final sub = repo.changes().listen((_) {});
    await sub.cancel();
    await _settle();
    final cached = repo.all();

    // A write that bypasses the repository can only invalidate the cache
    // through the watcher, so a stale cache proves the watcher is gone.
    await Hive.box<dynamic>('favorites').put(
      'busStop:direct',
      _favorite('direct').toMap(),
    );
    await _settle();

    expect(identical(repo.all(), cached), isTrue);
  });
}
