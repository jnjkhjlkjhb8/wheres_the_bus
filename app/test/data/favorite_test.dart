import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/models/favorite.dart';
import 'package:wheres_the_bus/features/favorites/favorite_actions.dart';
import 'package:wheres_the_bus/shared/widgets/transport_icon.dart';

void main() {
  test('Favorite id is type-scoped and stable', () {
    const fav = Favorite(
      type: FavoriteType.busStop,
      refId: '台北車站',
      title: '台北車站',
    );
    expect(fav.id, 'busStop:台北車站');
  });

  test('Favorite survives a map round-trip', () {
    const fav = Favorite(
      type: FavoriteType.metroStation,
      refId: 'BL12',
      title: '台北車站',
      subtitle: '板南線',
      pinned: true,
      order: 3,
      createdAt: 42,
    );
    expect(Favorite.fromMap(fav.toMap()), fav);
  });

  test('metro favorite resolves its line colour from the ref id', () {
    TransportType lineOf(String id) => transportTypeForFavorite(
      Favorite(type: FavoriteType.metroStation, refId: id, title: id),
    );
    expect(lineOf('BL12'), TransportType.mrtBL);
    expect(lineOf('R10'), TransportType.mrtR);
    expect(lineOf('G14'), TransportType.mrtG);
    expect(lineOf('BR09'), TransportType.mrtBR);
    expect(lineOf('O12'), TransportType.mrtO);
  });

  test('each favorite type maps to an icon', () {
    for (final type in FavoriteType.values) {
      final icon = transportTypeForFavorite(
        Favorite(type: type, refId: 'x', title: 'x'),
      );
      expect(icon, isA<TransportType>());
    }
  });
}
