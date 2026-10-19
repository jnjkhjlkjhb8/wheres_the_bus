import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart';
import 'package:hive_ce/hive.dart';
import 'package:wheres_the_bus/core/firebase/firebase_gate.dart';
import 'package:wheres_the_bus/data/generated/firebase.pbgrpc.dart' as pb;
import 'package:wheres_the_bus/data/models/firebase_models.dart';
import 'package:wheres_the_bus/data/repositories/firebase_repository.dart';
import 'package:wheres_the_bus/data/repositories/settings_repository.dart';

import '../../support/helpers/fake_grpc.dart';
import '../../support/helpers/in_memory_settings_store.dart';

class FakeFirebase implements pb.Firebase_ServiceClient {
  pb.UpsertDeviceRequest? upsert;
  pb.RouteSubscriptionsRequest? subscriptions;
  pb.CreateArrivalReminderRequest? arrival;
  pb.CancelArrivalReminderRequest? cancellation;
  pb.DeviceRequest? listing;
  final metadata = <Map<String, String>>[];
  Object? failure;
  ResponseFuture<T> respond<T>(T value, CallOptions? options) {
    metadata.add(options!.metadata);
    final error = failure;
    return FakeResponseFuture(
      error == null ? Future.value(value) : Future.error(error),
    );
  }

  @override
  ResponseFuture<pb.DeviceState> upsertDevice(
    pb.UpsertDeviceRequest request, {
    CallOptions? options,
  }) {
    upsert = request;
    return respond(
      pb.DeviceState(identity: request.identity, prefs: request.prefs),
      options,
    );
  }

  @override
  ResponseFuture<pb.Ack> replaceRouteSubscriptions(
    pb.RouteSubscriptionsRequest request, {
    CallOptions? options,
  }) {
    subscriptions = request;
    return respond(pb.Ack(ok: true, message: 'replaced'), options);
  }

  @override
  ResponseFuture<pb.ArrivalReminder> createArrivalReminder(
    pb.CreateArrivalReminderRequest request, {
    CallOptions? options,
  }) {
    arrival = request;
    return respond(pb.ArrivalReminder(reminderId: 'reminder'), options);
  }

  @override
  ResponseFuture<pb.Ack> cancelArrivalReminder(
    pb.CancelArrivalReminderRequest request, {
    CallOptions? options,
  }) {
    cancellation = request;
    return respond(pb.Ack(ok: true, message: 'cancelled'), options);
  }

  @override
  ResponseFuture<pb.DeviceState> listDeviceState(
    pb.DeviceRequest request, {
    CallOptions? options,
  }) {
    listing = request;
    return respond(
      pb.DeviceState(
        identity: pb.DeviceIdentity(
          installId: request.installId,
          fcmToken: 'stored',
          platform: 'ios',
          appVersion: 'version',
        ),
        prefs: pb.DevicePrefs(pushEnabled: true),
      ),
      options,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('enabled Firebase repository contracts', () {
    late Directory storage;
    setUpAll(() async {
      expect(
        FirebaseGate.enabled,
        isTrue,
        reason: 'Run this harness with env/quality-firebase.json',
      );
      storage = await Directory.systemTemp.createTemp(
        'firebase-repository-contract-',
      );
      Hive.init(storage.path);
      await Hive.openBox<dynamic>('settings');
    });
    setUp(() {
      FlutterSecureStorage.setMockInitialValues({
        'firebase_install_pair': jsonEncode({
          'id': 'quality-install',
          'secret': 'quality-secret',
        }),
      });
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    });
    tearDown(() => debugDefaultTargetPlatformOverride = null);
    tearDownAll(() async {
      await Hive.close();
      await storage.delete(recursive: true);
    });

    test(
      'device writes carry installation credentials and preferences',
      () async {
        final client = FakeFirebase();
        final repo = FirebaseRepository(
          client: client,
          settings: SettingsRepository(
            store: InMemorySettingsStore({'push_enabled': false}),
          ),
        );
        final state = await repo.upsertDevice(fcmToken: 'token');
        expect(
          state,
          const FirebaseDeviceState(
            installId: 'quality-install',
            fcmToken: 'token',
            platform: 'ios',
            appVersion: '1.0.0',
          ),
        );
        expect(client.upsert!.identity.installId, 'quality-install');
        expect(client.upsert!.identity.platform, 'ios');
        expect(client.upsert!.prefs.pushEnabled, isFalse);
        expect(client.metadata.single['x-install-id'], 'quality-install');
        expect(client.metadata.single['x-install-secret'], 'quality-secret');
        final listed = await repo.listDeviceState();
        expect(
          listed,
          const FirebaseDeviceState(
            installId: 'quality-install',
            fcmToken: 'stored',
            platform: 'ios',
            appVersion: 'version',
            pushEnabled: true,
          ),
        );
        expect(client.listing!.installId, 'quality-install');
      },
    );

    test(
      'subscription replacements retain operator scope and support clearing',
      () async {
        final client = FakeFirebase();
        final repo = FirebaseRepository(client: client);
        expect(
          await repo.replaceRouteSubscriptions({
            'bus:route:branch',
            'mrt:TRTC',
          }),
          const FirebaseAck(ok: true, message: 'replaced'),
        );
        expect(client.subscriptions!.installId, 'quality-install');
        expect(
          client.subscriptions!.subscriptions.map(
            (s) => (s.routeType, s.routeKey),
          ),
          [('bus', 'route:branch'), ('mrt', 'TRTC')],
        );
        await repo.replaceRouteSubscriptions({});
        expect(client.subscriptions!.subscriptions, isEmpty);
      },
    );

    test(
      'arrival writes preserve canonical identity, expiry and vehicle pin',
      () async {
        final client = FakeFirebase();
        final repo = FirebaseRepository(client: client);
        final expires = DateTime.utc(2026, 10, 10, 12);
        expect(
          await repo.createArrivalReminder(
            routeType: 'bus',
            routeKey: 'R',
            stopKey: 'S',
            direction: '1',
            leadMinutes: 2,
            expiresAt: expires,
            plate: 'KKA-1288',
            alightEvent: 'arrival',
          ),
          const ArrivalReminderReceipt(reminderId: 'reminder'),
        );
        final request = client.arrival!;
        expect(request.installId, 'quality-install');
        expect(request.routeType, 'bus');
        expect(request.routeKey, 'R');
        expect(request.stopKey, 'S');
        expect(request.direction, '1');
        expect(request.leadMinutes, 2);
        expect(request.plate, 'KKA-1288');
        expect(request.alightEvent, 'arrival');
        expect(
          request.expiresAtUnix.toInt(),
          expires.millisecondsSinceEpoch ~/ 1000,
        );
        expect(
          await repo.cancelArrivalReminder('reminder'),
          const FirebaseAck(ok: true, message: 'cancelled'),
        );
        expect(client.cancellation!.installId, 'quality-install');
        expect(client.cancellation!.reminderId, 'reminder');
      },
    );

    test('server errors remain observable to repository callers', () async {
      final client = FakeFirebase()..failure = const GrpcError.unavailable();
      final repo = FirebaseRepository(client: client);
      await expectLater(
        repo.upsertDevice(fcmToken: 'token'),
        throwsA(isA<GrpcError>()),
      );
      await expectLater(repo.listDeviceState(), throwsA(isA<GrpcError>()));
      await expectLater(
        repo.replaceRouteSubscriptions({}),
        throwsA(isA<GrpcError>()),
      );
      await expectLater(
        repo.cancelArrivalReminder('id'),
        throwsA(isA<GrpcError>()),
      );
      await expectLater(
        repo.createArrivalReminder(
          routeType: 'tra',
          routeKey: 'R',
          stopKey: 'S',
          direction: '0',
          leadMinutes: 0,
          expiresAt: DateTime(2026),
        ),
        throwsA(isA<GrpcError>()),
      );
    });
  });
}
