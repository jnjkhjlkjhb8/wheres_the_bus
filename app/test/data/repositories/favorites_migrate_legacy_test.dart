import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:wheres_the_bus/core/storage/hive_store.dart';
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
  });
}
