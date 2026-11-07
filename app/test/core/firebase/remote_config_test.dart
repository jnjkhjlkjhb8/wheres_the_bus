import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/core/firebase/remote_config.dart';

void main() {
  test(
    'offline configuration retains transit thresholds and typed defaults',
    () {
      expect(AppConfig.getInt('eta_approaching_threshold_s'), 30);
      expect(AppConfig.getInt('nearby_fallback_radius_m'), 900);
      expect(AppConfig.getBool('push_enabled'), isTrue);
      expect(AppConfig.getBool('maintenance_banner_enabled'), isFalse);
      expect(AppConfig.getString('min_supported_version'), '0.1.0');
      expect(AppConfig.getString('maintenance_banner_text'), '');
    },
  );

  test('revision stream broadcasts changes while subscribers remain', () async {
    final original = AppConfig.version.value;
    var firstEvents = 0;
    var secondEvents = 0;
    final revisions = AppConfig.revisions();
    final first = revisions.listen((_) => firstEvents++);
    StreamSubscription<void>? second;
    try {
      second = revisions.listen((_) => secondEvents++);
      await Future<void>.delayed(Duration.zero);
      expect(firstEvents, 0);
      expect(secondEvents, 0);

      AppConfig.version.value++;
      await Future<void>.delayed(Duration.zero);
      expect(firstEvents, 1);
      expect(secondEvents, 1);

      await first.cancel();
      AppConfig.version.value++;
      await Future<void>.delayed(Duration.zero);
      expect(firstEvents, 1);
      expect(secondEvents, 2);
    } finally {
      try {
        await Future.wait<void>([
          first.cancel(),
          if (second != null) second.cancel(),
        ]);
      } finally {
        AppConfig.version.value = original;
      }
    }
  });

  test(
    'revision stream resumes once after its last subscriber cancels',
    () async {
      final original = AppConfig.version.value;
      final revisions = AppConfig.revisions();
      var beforeCancel = 0;
      var afterResume = 0;
      final first = revisions.listen((_) => beforeCancel++);
      StreamSubscription<void>? resumed;
      try {
        AppConfig.version.value++;
        await Future<void>.delayed(Duration.zero);
        expect(beforeCancel, 1);
        await first.cancel();

        AppConfig.version.value++;
        await Future<void>.delayed(Duration.zero);
        expect(beforeCancel, 1);

        resumed = revisions.listen((_) => afterResume++);
        await Future<void>.delayed(Duration.zero);
        expect(afterResume, 0);
        AppConfig.version.value++;
        await Future<void>.delayed(Duration.zero);
        expect(afterResume, 1);
        expect(beforeCancel, 1);
      } finally {
        try {
          await Future.wait<void>([
            first.cancel(),
            if (resumed != null) resumed.cancel(),
          ]);
        } finally {
          AppConfig.version.value = original;
        }
      }
    },
  );
}
