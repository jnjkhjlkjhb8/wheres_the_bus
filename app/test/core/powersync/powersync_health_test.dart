import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/core/powersync/powersync_health.dart';

void main() {
  group('PowerSyncHealth', () {
    test('reports the first error from a source stream', () async {
      final controller = StreamController<String?>();
      final reported = <Object>[];
      final health = PowerSyncHealth<String?>(
        errorOf: (e) => e,
        onError: reported.add,
      );

      final syncStream = controller.stream;
      health.listen(syncStream);
      controller.add('boom');
      await Future<void>.delayed(Duration.zero);

      expect(reported, ['boom']);
      await health.cancel();
      await controller.close();
    });

    test('de-dupes repeated identical errors', () async {
      final controller = StreamController<String?>();
      final reported = <Object>[];
      final health = PowerSyncHealth<String?>(
        errorOf: (e) => e,
        onError: reported.add,
      );

      final syncStream = controller.stream;
      health.listen(syncStream);
      controller
        ..add('boom')
        ..add('boom')
        ..add('boom');
      await Future<void>.delayed(Duration.zero);

      expect(reported, ['boom']);
      await health.cancel();
      await controller.close();
    });

    test('clears the dedupe key once the source recovers', () async {
      final controller = StreamController<String?>();
      final reported = <Object>[];
      final health = PowerSyncHealth<String?>(
        errorOf: (e) => e,
        onError: reported.add,
      );

      final syncStream = controller.stream;
      health.listen(syncStream);
      controller
        ..add('boom')
        ..add(null)
        ..add('boom');
      await Future<void>.delayed(Duration.zero);

      expect(reported, ['boom', 'boom']);
      await health.cancel();
      await controller.close();
    });

    test('cancel stops delivering further errors', () async {
      final controller = StreamController<String?>();
      final reported = <Object>[];
      final health = PowerSyncHealth<String?>(
        errorOf: (e) => e,
        onError: reported.add,
      );

      final syncStream = controller.stream;
      health.listen(syncStream);
      await health.cancel();
      controller.add('after-cancel');
      await Future<void>.delayed(Duration.zero);

      expect(reported, isEmpty);
      await controller.close();
    });

    test('lastSyncedAt is null until freshnessOf reports a sync', () async {
      final controller = StreamController<String?>();
      final health = PowerSyncHealth<String?>(
        errorOf: (e) => e,
        onError: (_) {},
      );

      final stream = controller.stream;
      health.listen(stream);
      expect(health.lastSyncedAt, isNull);

      await health.cancel();
      await controller.close();
    });

    test('lastSyncedAt tracks the latest value from freshnessOf', () async {
      final controller = StreamController<DateTime?>();
      final synced = DateTime.utc(2026, 7, 16, 6);
      final health = PowerSyncHealth<DateTime?>(
        errorOf: (_) => null,
        onError: (_) {},
        freshnessOf: (status) => status,
      );

      final stream = controller.stream;
      health.listen(stream);
      controller.add(synced);
      await Future<void>.delayed(Duration.zero);

      expect(health.lastSyncedAt, synced);
      await health.cancel();
      await controller.close();
    });

    test('lastSyncedAt keeps the previous value on a null status', () async {
      final controller = StreamController<DateTime?>();
      final synced = DateTime.utc(2026, 7, 16, 6);
      final health = PowerSyncHealth<DateTime?>(
        errorOf: (_) => null,
        onError: (_) {},
        freshnessOf: (status) => status,
      );

      final stream = controller.stream;
      health.listen(stream);
      controller
        ..add(synced)
        ..add(null);
      await Future<void>.delayed(Duration.zero);

      // A status event without a synced timestamp (e.g. mid-download)
      // doesn't erase the last known-good freshness.
      expect(health.lastSyncedAt, synced);
      await health.cancel();
      await controller.close();
    });

    test('cancel() clears lastSyncedAt', () async {
      final controller = StreamController<DateTime?>();
      final synced = DateTime.utc(2026, 7, 16, 6);
      final health = PowerSyncHealth<DateTime?>(
        errorOf: (_) => null,
        onError: (_) {},
        freshnessOf: (status) => status,
      );

      final stream = controller.stream;
      health.listen(stream);
      controller.add(synced);
      await Future<void>.delayed(Duration.zero);
      await health.cancel();

      expect(health.lastSyncedAt, isNull);
      await controller.close();
    });

    test(
      'listen() again (reinit) cancels the previous subscription first',
      () async {
        final first = StreamController<String?>();
        final second = StreamController<String?>();
        final reported = <Object>[];
        final health = PowerSyncHealth<String?>(
          errorOf: (e) => e,
          onError: reported.add,
        );

        final firstStream = first.stream;
        health.listen(firstStream);
        first.add('from-first');
        await Future<void>.delayed(Duration.zero);
        expect(reported, ['from-first']);

        // Reinit: listening on `second` must cancel the subscription on
        // `first` first, or an event still in flight on the old source
        // would double-report.
        health.listen(second.stream);
        first.add('should-be-ignored');
        second.add('from-second');
        await Future<void>.delayed(Duration.zero);

        expect(reported, ['from-first', 'from-second']);
        await health.cancel();
        await first.close();
        await second.close();
      },
    );
  });
}
