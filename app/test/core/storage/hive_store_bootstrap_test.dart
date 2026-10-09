import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:wheres_the_bus/core/storage/hive_store.dart';

void main() {
  group('HiveStore.init', () {
    test('a failed init is visible to the caller and retryable', () async {
      Hive.init('./.dart_tool/hive_test_bootstrap');
      await Hive.openBox<int>('settings');

      // No-op binding: Hive.init() above already pointed Hive at a real
      // directory, and calling Hive.initFlutter() again would try to reach
      // path_provider, which has no platform binding under `flutter test`.
      Future<void> noopBinding() async {}

      await expectLater(
        HiveStore.init(initBinding: noopBinding),
        throwsA(anything),
      );

      // Fix the conflict and retry: init() must not be permanently memoized
      // as failed, and must not have left `App.isInitialized`-style state
      // claiming success while boxes are unopened.
      await Hive.box<int>('settings').close();
      await HiveStore.init(initBinding: noopBinding);

      expect(HiveStore.settingsReady, isTrue);
    });
  });
}
