import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:wheres_the_bus/core/storage/hive_store.dart';

void main() {
  late Directory storage;
  setUpAll(() async {
    storage = await Directory.systemTemp.createTemp('hive-preferences-');
    Hive.init(storage.path);
  });
  setUp(() async {
    await Hive.openBox<dynamic>('settings');
    await Hive.openBox<dynamic>('recent_searches');
    await Hive.openBox<dynamic>('static_cache');
  });
  tearDown(() async {
    await Hive.close();
  });
  tearDownAll(() async {
    await storage.delete(recursive: true);
  });

  test(
    'last device position accepts two numbers and rejects malformed cache',
    () async {
      for (final raw in [
        null,
        '25,121',
        [25],
        [25, '121'],
        ['25', 121],
      ]) {
        await HiveStore.settings.put('last_device_position', raw);
        expect(HiveStore.lastDevicePosition, isNull);
      }
      await HiveStore.setLastDevicePosition(25, 121);
      expect(HiveStore.lastDevicePosition, [25.0, 121.0]);
      await HiveStore.settings.close();
      expect(HiveStore.lastDevicePosition, isNull);
      await HiveStore.setLastDevicePosition(1, 2);
    },
  );

  test(
    'rail hemisphere and update dismissal round-trip only nonempty strings',
    () async {
      for (final raw in [null, '', 42]) {
        await HiveStore.settings.put('tra_hemisphere', raw);
        await HiveStore.settings.put('dismissed_update_version', raw);
        expect(HiveStore.traHemisphere, isNull);
        expect(HiveStore.dismissedUpdateVersion, isNull);
      }
      await HiveStore.setTraHemisphere('north');
      await HiveStore.setDismissedUpdateVersion('2.0.0');
      expect(HiveStore.traHemisphere, 'north');
      expect(HiveStore.dismissedUpdateVersion, '2.0.0');
      await HiveStore.settings.close();
      expect(HiveStore.traHemisphere, isNull);
      expect(HiveStore.dismissedUpdateVersion, isNull);
      await HiveStore.setTraHemisphere('south');
      await HiveStore.setDismissedUpdateVersion('3.0.0');
    },
  );

  test(
    'fresh static cache rejects future, expired and malformed timestamps',
    () async {
      final cache = HiveStore.staticCache;
      final now = DateTime.now().millisecondsSinceEpoch;
      for (final value in [
        null,
        [1, 2],
        {
          'b': [1],
        },
        {
          'b': [1],
          't': 'now',
        },
        {
          'b': [1],
          't': 0,
        },
        {
          'b': [1],
          't': now + 86400000,
        },
      ]) {
        await cache.put('route', value);
        expect(
          HiveStore.getStaticFresh('route', const Duration(hours: 1)),
          isNull,
        );
      }
      await HiveStore.putStatic('route', [1, 2, 3]);
      expect(HiveStore.getStaticFresh('route', const Duration(hours: 1)), [
        1,
        2,
        3,
      ]);
      await HiveStore.deleteStatic('route');
      expect(HiveStore.getStatic('route'), isNull);
      await cache.close();
      expect(
        HiveStore.getStaticFresh('route', const Duration(hours: 1)),
        isNull,
      );
    },
  );

  test('train recents stay ordered, deduplicated and limited to six', () async {
    for (var n = 0; n < 8; n++) {
      await HiveStore.addRecentTrainQuery('TRA', '$n');
    }
    await HiveStore.addRecentTrainQuery('TRA', '3');
    expect(HiveStore.recentTrainQueries.map((e) => e['trainNo']), [
      '3',
      '7',
      '6',
      '5',
      '4',
      '2',
    ]);
    await HiveStore.recents.close();
    expect(HiveStore.recentTrainQueries, isEmpty);
    await HiveStore.addRecentTrainQuery('TRA', '9');
  });

  test(
    'OD recents preserve latest ids while deduplicating station names',
    () async {
      Future<void> add(
        String system,
        String origin,
        String destination,
        String id,
      ) => HiveStore.addRecentOdQuery(
        system: system,
        originId: id,
        originName: origin,
        destId: 'end',
        destName: destination,
      );
      await add('TRA', 'Taipei', 'Taoyuan', 'old');
      await add('THSR', 'Taipei', 'Taoyuan', 'hsr');
      await add('TRA', 'Taipei', 'Taoyuan', 'new');
      expect(HiveStore.recentOdQueries, hasLength(2));
      expect(HiveStore.lastOdQuery('TRA')?['originId'], 'new');
      expect(HiveStore.lastOdQuery('THSR')?['originId'], 'hsr');
      expect(HiveStore.lastOdQuery('MRT'), isNull);
      for (var n = 0; n < 8; n++) {
        await add('TRA', 'origin$n', 'dest$n', '$n');
      }
      expect(HiveStore.recentOdQueries, hasLength(6));
      await HiveStore.recents.close();
      expect(HiveStore.recentOdQueries, isEmpty);
      expect(HiveStore.lastOdQuery('TRA'), isNull);
      await add('TRA', 'ignored', 'ignored', 'ignored');
    },
  );
}
