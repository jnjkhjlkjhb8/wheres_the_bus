import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/models/favorite.dart';
import 'package:wheres_the_bus/data/models/subscription_scope.dart';

Favorite _fav(FavoriteType type, String refId) =>
    Favorite(type: type, refId: refId, title: refId);

void main() {
  test('a bus route 收藏 is its own subscription key', () {
    expect(subscriptionScope([_fav(FavoriteType.busRoute, 'TPE10132')]), {
      'bus:TPE10132',
    });
  });

  test('a metro station resolves to the lines serving it', () {
    expect(subscriptionScope([_fav(FavoriteType.metroStation, 'BL12_R10')]), {
      'mrt:BL',
      'mrt:R',
    });
    expect(subscriptionScope([_fav(FavoriteType.metroStation, 'BR01')]), {
      'mrt:BR',
    });
  });

  // A 收藏 does not record which rail system it belongs to, so both are
  // claimed. The wrong one matches no alert scope and costs nothing.
  test('a rail train claims the number on both rail systems', () {
    expect(subscriptionScope([_fav(FavoriteType.railTrain, '123')]), {
      'tra:123',
      'thsr:123',
    });
  });

  test('a rail station resolves to the line-wide marker only', () {
    final scope = subscriptionScope([_fav(FavoriteType.railStation, '1000')]);
    expect(scope, {'tra:*', 'thsr:*'});
    // The station id itself must not become a key: no alert is ever scoped to
    // a station, so it would only ever match nothing.
    expect(scope, isNot(contains('tra:1000')));
  });

  // No alert source scopes to a stop, so expanding a busy stop into every
  // route calling at it would only manufacture noise. 到站提醒 covers the need.
  test('bus stops and bike stations subscribe to nothing', () {
    expect(
      subscriptionScope([
        _fav(FavoriteType.busStop, '台北車站'),
        _fav(FavoriteType.bikeStation, 'YouBike-1'),
      ]),
      isEmpty,
    );
  });

  test('two 收藏 on the same line collapse to one subscription', () {
    expect(
      subscriptionScope([
        _fav(FavoriteType.metroStation, 'BL12_R10'),
        _fav(FavoriteType.metroStation, 'BL13'),
      ]),
      {'mrt:BL', 'mrt:R'},
    );
  });

  test('no 收藏 is an empty scope, not a missing one', () {
    expect(subscriptionScope(const []), isEmpty);
  });
}
