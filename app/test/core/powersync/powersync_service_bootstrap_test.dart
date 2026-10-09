import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/core/powersync/powersync_service.dart';

void main() {
  group('PowerSyncService bootstrap', () {
    test('db access before init throws StateError (not an assert)', () {
      // A fresh instance so no other test's init() call has raced ahead of
      // this one. debugDisableAssertions must not affect this: the guard is
      // a runtime StateError so it also fires in release builds.
      final service = PowerSyncService.forTesting();

      expect(() => service.db, throwsStateError);
    });

    test('concurrent init() calls share a single in-flight future', () {
      final service = PowerSyncService.forTesting();

      final first = service.init();
      final second = service.init();

      expect(identical(first, second), isTrue);

      // Both futures settle (path_provider has no platform binding under
      // flutter test); avoid leaving an unhandled rejection behind.
      unawaited(first.catchError((_) {}));
    });

    test('readyDb waits for init and surfaces its failure', () async {
      final service = PowerSyncService.forTesting();

      await expectLater(service.readyDb, throwsA(anything));
    });
  });
}
