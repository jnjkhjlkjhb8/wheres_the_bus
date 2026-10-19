import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/models/favorite.dart';
import 'package:wheres_the_bus/features/favorites/bloc/favorites_event.dart';

void main() {
  const a = Favorite(type: FavoriteType.busStop, refId: '1', title: 'A');
  const b = Favorite(type: FavoriteType.busRoute, refId: '2', title: 'B');

  test('refresh event carries no props', () {
    expect(const FavoritesRefreshed().props, isEmpty);
    expect(const FavoritesRefreshed(), const FavoritesRefreshed());
  });

  test('FavoriteToggled compares the favorite', () {
    expect(const FavoriteToggled(a), const FavoriteToggled(a));
    expect(const FavoriteToggled(a), isNot(const FavoriteToggled(b)));
  });

  test('FavoritePinChanged compares id and pinned', () {
    const changed = FavoritePinChanged('x', pinned: true);
    expect(changed, const FavoritePinChanged('x', pinned: true));
    expect(changed, isNot(const FavoritePinChanged('y', pinned: true)));
    expect(changed, isNot(const FavoritePinChanged('x', pinned: false)));
  });

  test('FavoriteRemoved compares the id', () {
    expect(const FavoriteRemoved('x'), const FavoriteRemoved('x'));
    expect(const FavoriteRemoved('x'), isNot(const FavoriteRemoved('y')));
  });

  test('FavoritesReordered compares the order', () {
    expect(const FavoritesReordered([a, b]), const FavoritesReordered([a, b]));
    expect(
      const FavoritesReordered([a, b]),
      isNot(const FavoritesReordered([b, a])),
    );
  });
}
