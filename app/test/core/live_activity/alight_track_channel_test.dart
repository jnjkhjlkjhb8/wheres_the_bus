import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/core/live_activity/alight_track.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.wheres.bus/live_activity');
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          // The permission ask is not a card command: it fires at most once per
          // process, so recording it would make every assertion below depend on
          // which test happened to run first.
          if (call.method != 'requestNotificationPermission') calls.add(call);
          return call.method == 'start' ? 'activity-1' : null;
        });
  });

  const content = AlightTrackContent(
    mode: AlightTrackMode.bus,
    phase: AlightTrackPhase.waiting,
    vehicleLabel: '307',
    boardStation: '台北車站',
    targetStation: '板橋',
    nextStation: '台北車站',
    hopCount: 8,
    currentIndex: 0,
    remainingStops: 8,
    leadStops: 2,
    etaMs: 1234567890000,
    walkMinutes: 5,
  );

  test('start sends the whole unified arg map', () async {
    final la = AlightTrackChannel();
    await la.start(content);
    expect(calls.single.method, 'start');
    final args = Map<String, Object?>.from(calls.single.arguments as Map);
    expect(args['mode'], 'bus');
    expect(args['phase'], 'waiting');
    expect(args['hopCount'], 8);
    expect(args['leadStops'], 2);
    expect(args['etaMs'], 1234567890000);
    // The board surface is gone: no mode string may reintroduce it.
    expect(args.containsKey('routes'), isFalse);
  });

  test('update after start, stop clears', () async {
    final la = AlightTrackChannel();
    final lease = await la.start(content);
    await la.update(lease, content);
    await la.stop(lease);
    expect(calls.map((c) => c.method), ['start', 'update', 'stop']);
  });

  test('platform errors are swallowed — navigation must not crash', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          throw PlatformException(code: 'LA_START_FAILED');
        });
    final la = AlightTrackChannel();
    final lease = await la.start(content); // must not throw
    await la.stop(lease);
  });

  test('start hands back a fresh lease each call', () async {
    final la = AlightTrackChannel();
    final leaseA = await la.start(content);
    final leaseB = await la.start(content);
    expect(leaseA, isNot(leaseB));
  });

  test(
    'update under a superseded lease is a no-op (F37 lease ownership)',
    () async {
      final la = AlightTrackChannel();
      final leaseA = await la.start(content);
      final leaseB = await la.start(content);
      calls.clear();

      await la.update(leaseA, content);
      expect(calls, isEmpty);

      await la.update(leaseB, content);
      expect(calls.single.method, 'update');
    },
  );

  test(
    'stop under a superseded lease does not touch the platform channel '
    '(F37: a late stop from the old owner cannot kill a newly started '
    'activity)',
    () async {
      final la = AlightTrackChannel();
      final leaseA = await la.start(content);
      final leaseB = await la.start(content);
      calls.clear();

      await la.stop(leaseA); // stale — leaseB already superseded it
      expect(calls, isEmpty);

      await la.stop(leaseB);
      expect(calls.single.method, 'stop');
    },
  );

  test(
    'a delayed old-stop queued after a new start still no-ops even when '
    'both are in flight concurrently',
    () async {
      final la = AlightTrackChannel();
      final leaseA = await la.start(content);
      calls.clear();

      // Fire the stale stop and the new start back-to-back without
      // awaiting either individually, mirroring a real race where the old
      // owner's stop is dispatched around the same time a new owner starts.
      final stopFuture = la.stop(leaseA);
      final startFuture = la.start(content);
      await Future.wait([stopFuture, startFuture]);

      final leaseB = await startFuture;
      calls.clear();
      await la.stop(leaseA); // now definitely stale
      expect(calls, isEmpty);
      await la.stop(leaseB);
      expect(calls.single.method, 'stop');
    },
  );

  test(
    'start resolves and the queue keeps moving when the platform never '
    'answers (a hung start used to leave the card unposted, unupdatable and '
    'un-cancellable)',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            // Never completes: the shape of a `start` whose permission
            // callback never arrived.
            return Completer<Object?>().future;
          });
      final la = AlightTrackChannel();

      await la.start(content); // must not hang forever
      // The rider's cancel is behind the same serial queue, so this is the
      // half that actually broke: it has to run despite the start above.
      await la.stopAny();

      expect(calls.map((c) => c.method), contains('stop'));
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test('stopAny takes the card down without a lease', () async {
    final la = AlightTrackChannel();
    // No start: nothing ever handed this owner a lease, which is exactly the
    // state a rider pressing 取消追蹤 can be in.
    await la.stopAny();
    expect(calls.single.method, 'stop');
  });
}
