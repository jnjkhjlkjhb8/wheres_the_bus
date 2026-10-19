import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/repositories/firebase_repository.dart';

void main() {
  test('disabled Firebase operations return local acknowledgements', () async {
    final repo = FirebaseRepository();
    expect((await repo.upsertDevice(fcmToken: 'unused')).installId, '');
    expect((await repo.listDeviceState()).installId, '');
    expect(
      (await repo.replaceRouteSubscriptions({'bus:R'})).message,
      'disabled',
    );
    expect((await repo.cancelArrivalReminder('local')).message, 'disabled');
  });

  test(
    'arrival validation rejects unsupported modes and incomplete identities',
    () async {
      final repo = FirebaseRepository();
      for (final identity in [
        ('mrt', 'R', 'S', '0'),
        ('bus', '', 'S', '0'),
        ('bus', 'R', '', '0'),
        ('bus', 'R', 'S', '2'),
      ]) {
        await expectLater(
          repo.createArrivalReminder(
            routeType: identity.$1,
            routeKey: identity.$2,
            stopKey: identity.$3,
            direction: identity.$4,
            leadMinutes: 1,
            expiresAt: DateTime(2026),
          ),
          throwsArgumentError,
        );
      }
    },
  );

  // UpsertDevice and the firebase_device CHECK constraint accept only
  // 'android' and 'ios'. TargetPlatform.iOS.name is 'iOS', so sending the
  // enum name verbatim made every iOS registration fail with InvalidArgument.
  group('devicePlatform', () {
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
      test('is server-accepted on $platform', () {
        debugDefaultTargetPlatformOverride = platform;
        expect(devicePlatform(), anyOf('android', 'ios'));
      });
    }
  });

  group('createArrivalReminder plate pinning', () {
    test('local id includes the plate when one is passed', () async {
      final repo = FirebaseRepository();
      final receipt = await repo.createArrivalReminder(
        routeType: 'bus',
        routeKey: 'R1',
        stopKey: 'S1',
        direction: '0',
        leadMinutes: 1,
        expiresAt: DateTime(2026),
        plate: 'KKA-1288',
      );
      expect(receipt.reminderId, 'local:bus:R1:S1:1:KKA-1288:');
    });

    test('local id omits the plate when none is passed', () async {
      final repo = FirebaseRepository();
      final receipt = await repo.createArrivalReminder(
        routeType: 'bus',
        routeKey: 'R1',
        stopKey: 'S1',
        direction: '0',
        leadMinutes: 1,
        expiresAt: DateTime(2026),
      );
      expect(receipt.reminderId, 'local:bus:R1:S1:1::');
    });

    test('pinned and unpinned local ids differ', () async {
      final repo = FirebaseRepository();
      final pinned = await repo.createArrivalReminder(
        routeType: 'bus',
        routeKey: 'R1',
        stopKey: 'S1',
        direction: '0',
        leadMinutes: 1,
        expiresAt: DateTime(2026),
        plate: 'KKA-1288',
      );
      final unpinned = await repo.createArrivalReminder(
        routeType: 'bus',
        routeKey: 'R1',
        stopKey: 'S1',
        direction: '0',
        leadMinutes: 1,
        expiresAt: DateTime(2026),
      );
      expect(pinned.reminderId, isNot(unpinned.reminderId));
    });
  });
}
