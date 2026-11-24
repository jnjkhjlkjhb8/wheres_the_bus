import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/models/favorite.dart';
import 'package:wheres_the_bus/features/favorites/bloc/favorites_state.dart';

Favorite _fav(String id, {bool pinned = false}) => Favorite(
  type: FavoriteType.busRoute,
  refId: id,
  title: id,
  pinned: pinned,
);

void main() {
  test(
    'home lists every favorite, pinned ones first, order otherwise kept',
    () {
      final state = FavoritesState(
        items: [
          _fav('a'),
          _fav('b', pinned: true),
          _fav('c'),
          _fav('d', pinned: true),
        ],
      );

      expect([for (final f in state.forHome) f.refId], ['b', 'd', 'a', 'c']);
      expect([for (final f in state.pinned) f.refId], ['b', 'd']);
    },
  );

  test('nothing saved means nothing on home', () {
    expect(const FavoritesState().forHome, isEmpty);
  });
}
