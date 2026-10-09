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
}
