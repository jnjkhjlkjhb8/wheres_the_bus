import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:wheres_the_bus/core/storage/hive_store.dart';

void main() {
  test('saved-plan writes wait for lazy storage readiness', () async {
    final storage = await Directory.systemTemp.createTemp(
      'hive-saved-plan-readiness-',
    );
    Hive.init(storage.path);
    final bindingReady = Completer<void>();
    var initialized = false;
    final init =
        HiveStore.init(initBinding: () => bindingReady.future).then<void>((_) {
          initialized = true;
        })..ignore();
    final write = HiveStore.putSavedPlan('route-1', const [1, 2, 3])..ignore();
    var completed = false;
    final observed = write.whenComplete(() => completed = true)..ignore();

    try {
      await Future<void>.delayed(Duration.zero);
      expect(HiveStore.savedPlansReady, isFalse);
      expect(completed, isFalse);

      bindingReady.complete();
      await Future.wait<void>([init, write, observed]);

      expect(HiveStore.savedPlansReady, isTrue);
      expect(HiveStore.savedPlanEntries.single['key'], 'route-1');
    } finally {
      if (!bindingReady.isCompleted) bindingReady.complete();
      try {
        await Future.wait<void>([init, write, observed]);
      } finally {
        try {
          if (initialized) {
            // Public openBox joins lazy opens before closing their handles.
            await Future.wait([
              Hive.openBox<dynamic>('board_layout'),
              Hive.openBox<dynamic>('arrival_reminders'),
              Hive.openBox<dynamic>('recent_searches'),
              Hive.openBox<dynamic>('static_cache'),
            ]);
          }
        } finally {
          try {
            await Hive.close();
          } finally {
            await storage.delete(recursive: true);
          }
        }
      }
    }
  });
}
