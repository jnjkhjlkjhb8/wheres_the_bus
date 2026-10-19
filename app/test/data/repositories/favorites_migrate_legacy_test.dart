import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:wheres_the_bus/core/storage/hive_store.dart';
import 'package:wheres_the_bus/data/models/favorite.dart';
import 'package:wheres_the_bus/data/repositories/favorites_repository.dart';

void main() {
  group('FavoritesRepository.migrateLegacy', () {
    test(
      'runs against open boxes when fired alongside HiveStore.init',
      () async {
        Hive.init('./.dart_tool/hive_test_favorites_migrate');

        // No-op binding: Hive.init() above already pointed Hive at a real
        // directory, and Hive.initFlutter() would reach path_provider, which
        // has no platform binding under `flutter test`.
        Future<void> noopBinding() async {}

        // Mirrors main(): the bootstrap kicks off HiveStore.init, then
        // migrateLegacy is fired without awaiting it. The boxes are still
        // opening at this point.
        unawaited(HiveStore.init(initBinding: noopBinding));
        expect(HiveStore.settingsReady, isFalse);

        await FavoritesRepository.instance.migrateLegacy();

        expect(HiveStore.settingsReady, isTrue);
      },
    );
    test(
      'legacy rows migrate once while existing identities stay intact',
      () async {
        Hive.init('./.dart_tool/hive_test_favorites_migrate_contract');
        Future<void> noopBinding() async {}
        await HiveStore.init(initBinding: noopBinding);
        final repo = FavoritesRepository.instance;
        await HiveStore.favorites.clear();
        await HiveStore.favRoutes.clear();
        await HiveStore.settings.put('favorites_migrated', false);
        await HiveStore.settings.put('fav_bus_stops', ['stop', 'stop']);
        await HiveStore.settings.put('fav_metro_stations', ['BL01', 'unknown']);
        await HiveStore.favRoutes.putAll({
          'bus': {
            'route_type': 'bus',
            'route_key': 'route',
            'route_label': 'Route',
          },
          'rail': {
            'route_type': 'tra',
            'route_key': 'train',
            'route_label': 'Train',
          },
          'fallback': <String, dynamic>{},
          'invalid': 3,
        });
        await repo.add(
          const Favorite(
            type: FavoriteType.busStop,
            refId: 'stop',
            title: 'Existing',
            createdAt: 23,
          ),
        );
        await repo.migrateLegacy();
        final rows = {for (final fav in repo.all()) fav.id: fav};
        expect(rows, hasLength(6));
        expect(rows['busStop:stop']!.title, 'Existing');
        expect(rows['busStop:stop']!.createdAt, 23);
        expect(rows['metroStation:BL01']!.title, '頂埔');
        expect(rows['metroStation:unknown']!.title, 'unknown');
        expect(rows['busRoute:route']!.title, 'Route');
        expect(rows['railTrain:train']!.title, 'Train');
        expect(rows['busRoute:fallback']!.title, 'fallback');
        expect(rows.values.map((f) => f.order), [0, 1, 2, 3, 4, 5]);
        await HiveStore.settings.put('fav_bus_stops', ['later']);
        await repo.migrateLegacy();
        expect(repo.isFavorite('busStop:later'), isFalse);
        expect(HiveStore.settings.get('favorites_migrated'), isTrue);
      },
    );
  });
}
