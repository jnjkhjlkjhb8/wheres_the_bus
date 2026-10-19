import 'dart:convert';
import 'dart:io';

import 'package:fixnum/fixnum.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart';
import 'package:hive_ce/hive.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:wheres_the_bus/data/generated/feedback.pbgrpc.dart' as feedback;
import 'package:wheres_the_bus/data/generated/mrt.pbgrpc.dart' as mrt;
import 'package:wheres_the_bus/data/models/feedback_models.dart';
import 'package:wheres_the_bus/data/models/mrt_track_models.dart';
import 'package:wheres_the_bus/data/repositories/feedback_repository.dart';
import 'package:wheres_the_bus/data/repositories/mrt_track_repository.dart';

import '../../support/helpers/fake_grpc.dart';

class FakeFeedback implements feedback.Feedback_ServiceClient {
  feedback.PostFeedbackRequest? request;
  Object? failure;
  @override
  ResponseFuture<feedback.ReportReceipt> postFeedback(
    feedback.PostFeedbackRequest request, {
    CallOptions? options,
  }) {
    this.request = request;
    final error = failure;
    return FakeResponseFuture(
      error == null
          ? Future.value(
              feedback.ReportReceipt(
                threadId: 'abcd-1234',
                createdAtUnix: Int64(1000),
              ),
            )
          : Future.error(error),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

mrt.MrtTrackState trackState({
  String system = '',
  String status = 'tracking',
}) => mrt.MrtTrackState(
  trackId: 'track',
  tripId: 'trip',
  carId: 'car',
  pathStationIds: ['BL01', 'BL02'],
  pathStationNames: ['頂埔', '永寧'],
  targetIndex: 1,
  currentIndex: 0,
  remainingStops: 1,
  nextStationId: 'BL02',
  nextStationName: '永寧',
  progress: 0.5,
  status: status,
  leadStops: 2,
  system: system,
);

class FakeTrack implements mrt.Mrt_ServiceClient {
  mrt.CreateMrtTrackRequest? created;
  mrt.SetMrtTrackPushTokenRequest? push;
  mrt.CancelMrtTrackRequest? cancelled;
  mrt.WatchMrtTrackRequest? watched;
  Object? failure;
  @override
  ResponseFuture<mrt.MrtTrackState> createTrack(
    mrt.CreateMrtTrackRequest request, {
    CallOptions? options,
  }) {
    created = request;
    final error = failure;
    return FakeResponseFuture(
      error == null ? Future.value(trackState()) : Future.error(error),
    );
  }

  @override
  ResponseStream<mrt.MrtTrackState> watchTrack(
    mrt.WatchMrtTrackRequest request, {
    CallOptions? options,
  }) {
    watched = request;
    return FakeResponseStream(
      Stream.fromIterable([
        trackState(system: 'KRTC', status: 'lead_fired'),
        trackState(status: 'arrived'),
      ]),
    );
  }

  @override
  ResponseFuture<mrt.MrtTrackAck> setTrackPushToken(
    mrt.SetMrtTrackPushTokenRequest request, {
    CallOptions? options,
  }) {
    push = request;
    return FakeResponseFuture(Future.value(mrt.MrtTrackAck(ok: true)));
  }

  @override
  ResponseFuture<mrt.MrtTrackAck> cancelTrack(
    mrt.CancelMrtTrackRequest request, {
    CallOptions? options,
  }) {
    cancelled = request;
    return FakeResponseFuture(Future.value(mrt.MrtTrackAck(ok: true)));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory storage;
  setUpAll(() async {
    storage = await Directory.systemTemp.createTemp(
      'rider-transport-contract-',
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
  });
  tearDownAll(() async {
    await Hive.close();
    await storage.delete(recursive: true);
  });

  test(
    'report diagnostics normalize whitespace and truncate oversized fields',
    () async {
      final repo = FeedbackRepository(
        packageInfoLoader: () async => PackageInfo(
          appName: 'App',
          packageName: 'app',
          version: '1.2',
          buildNumber: '3',
        ),
        osVersionOf: () => '  os\n version  ',
      );
      final result = await repo.collect(
        screen: ' /bus\nroute ',
        locale: 'x' * 140,
      );
      expect(result.appVersion, '1.2+3');
      expect(result.osVersion, 'os version');
      expect(result.screen, '/bus route');
      expect(result.locale, 'x' * 128);
      expect(result.platform, isNotEmpty);
      final empty = await FeedbackRepository(
        packageInfoLoader: () async => throw StateError('unavailable'),
        osVersionOf: () => throw StateError('unavailable'),
      ).collect(screen: '', locale: '');
      expect(empty.appVersion, '');
      expect(empty.osVersion, '');
      final fallback = await FeedbackRepository(
        packageInfoLoader: () async => throw StateError('unavailable'),
      ).collect(screen: '', locale: '');
      expect(fallback.osVersion, isNotEmpty);
    },
  );

  test(
    'report submission preserves rider disclosure and server receipt',
    () async {
      final client = FakeFeedback();
      final repo = FeedbackRepository(client: client);
      const diagnostics = FeedbackDiagnostics(
        appVersion: 'version',
        platform: 'ios',
        osVersion: 'os',
        screen: '/settings',
        locale: 'zh',
      );
      final receipt = await repo.submit(
        category: FeedbackCategory.eta,
        body: 'Wrong time',
        diagnostics: diagnostics,
      );
      expect(receipt.threadId, 'abcd-1234');
      expect(receipt.createdAt.millisecondsSinceEpoch, 1000000);
      expect(client.request!.installId, 'quality-install');
      expect(client.request!.category, 'eta');
      expect(client.request!.body, 'Wrong time');
      expect(client.request!.diagnostics.appVersion, 'version');
      expect(client.request!.diagnostics.platform, 'ios');
      expect(client.request!.diagnostics.osVersion, 'os');
      expect(client.request!.diagnostics.screen, '/settings');
      expect(client.request!.diagnostics.locale, 'zh');
      client.failure = const GrpcError.resourceExhausted();
      await expectLater(
        repo.submit(
          category: FeedbackCategory.eta,
          body: 'Retry',
          diagnostics: diagnostics,
        ),
        throwsA(isA<GrpcError>()),
      );
    },
  );

  test(
    'metro tracking carries card identity and decodes lifecycle updates',
    () async {
      final client = FakeTrack();
      final repo = MrtTrackRepository(client: client);
      final created = await repo.createTrack(
        carId: 'car',
        boardStationId: 'BL01',
        destStationId: 'BL03',
        targetStationId: 'BL02',
        leadStops: 2,
        vehicleLabel: 'Vehicle',
        lineCode: 'BL',
        lineColorHex: '#123456',
      );
      expect(client.created!.installId, 'quality-install');
      expect(client.created!.system, 'TRTC');
      expect(client.created!.carId, 'car');
      expect(client.created!.boardStationId, 'BL01');
      expect(client.created!.destStationId, 'BL03');
      expect(client.created!.targetStationId, 'BL02');
      expect(client.created!.leadStops, 2);
      expect(client.created!.vehicleLabel, 'Vehicle');
      expect(client.created!.lineCode, 'BL');
      expect(client.created!.lineColorHex, '#123456');
      expect(created.trackId, 'track');
      expect(created.tripId, 'trip');
      expect(created.carId, 'car');
      expect(created.pathStationIds, ['BL01', 'BL02']);
      expect(created.pathStationNames, ['頂埔', '永寧']);
      expect(created.targetIndex, 1);
      expect(created.currentIndex, 0);
      expect(created.remainingStops, 1);
      expect(created.nextStationId, 'BL02');
      expect(created.nextStationName, '永寧');
      expect(created.progress, 0.5);
      expect(created.status, MrtTrackStatus.tracking);
      expect(created.leadStops, 2);
      expect(created.system, 'TRTC');
      final updates = await repo.watch('track').toList();
      expect(client.watched!.trackId, 'track');
      expect(updates.first.status, MrtTrackStatus.leadFired);
      expect(updates.first.system, 'KRTC');
      expect(updates.last.status, MrtTrackStatus.arrived);
      await repo.setPushToken('track', 'push');
      expect(client.push!.installId, 'quality-install');
      expect(client.push!.trackId, 'track');
      expect(client.push!.pushToken, 'push');
      await repo.cancel('track');
      expect(client.cancelled!.installId, 'quality-install');
      expect(client.cancelled!.trackId, 'track');
      client.failure = const GrpcError.notFound();
      await expectLater(
        repo.createTrack(
          carId: 'missing',
          boardStationId: 'BL01',
          destStationId: 'BL03',
          targetStationId: 'BL02',
          leadStops: 1,
        ),
        throwsA(isA<GrpcError>()),
      );
    },
  );
}
