import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus_platform_interface/connectivity_plus_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:grpc/grpc.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:wheres_the_bus/app/app.dart';
import 'package:wheres_the_bus/core/bootstrap/app_bootstrap.dart';
import 'package:wheres_the_bus/core/firebase/firebase_gate.dart';
import 'package:wheres_the_bus/core/grpc/grpc_client.dart';
import 'package:wheres_the_bus/core/lifecycle/app_foreground.dart';
import 'package:wheres_the_bus/core/lifecycle/app_network.dart';
import 'package:wheres_the_bus/core/live_activity/alight_track_inbound_channel.dart';
import 'package:wheres_the_bus/core/storage/hive_store.dart';
import 'package:wheres_the_bus/data/generated/alert.pbgrpc.dart' as alert;
import 'package:wheres_the_bus/data/generated/mrt.pbgrpc.dart' as mrt;
import 'package:wheres_the_bus/data/models/alert_models.dart';
import 'package:wheres_the_bus/data/models/mrt_track_models.dart';
import 'package:wheres_the_bus/data/models/plan_models.dart';
import 'package:wheres_the_bus/data/tracking/journey_models.dart';
import 'package:wheres_the_bus/data/tracking/journey_session_bloc.dart';
import 'package:wheres_the_bus/data/tracking/journey_session_event.dart';
import 'package:wheres_the_bus/data/tracking/journey_session_state.dart';
import 'package:wheres_the_bus/features/alerts/bloc/alert_bloc.dart';
import 'package:wheres_the_bus/features/metro/bloc/mrt_track_bloc.dart';

const _channel = MethodChannel('me.rabbitsayhello.wheresthebus/live_activity');
const _trackId = 'app-root-restored-mrt';
const _installId = 'app-root-install';

const _session = MrtTrackSession(
  trackId: _trackId,
  tripId: '215',
  carId: '1163',
  pathStationIds: ['BL12', 'BL13', 'BL14', 'BL18'],
  pathStationNames: ['台北車站', '善導寺', '忠孝新生', '市政府'],
  targetIndex: 3,
  currentIndex: 0,
  remainingStops: 3,
  nextStationId: 'BL13',
  nextStationName: '善導寺',
  progress: 0,
  status: MrtTrackStatus.tracking,
  leadStops: 1,
  system: 'TRTC',
);

class _LoopbackMrt extends mrt.Mrt_ServiceBase {
  final watched = <mrt.WatchMrtTrackRequest>[];
  final tokens = <mrt.SetMrtTrackPushTokenRequest>[];
  final cancelled = <mrt.CancelMrtTrackRequest>[];
  final _watches = <StreamController<mrt.MrtTrackState>>{};

  @override
  Stream<mrt.MrtTrackState> watchTrack(
    ServiceCall call,
    mrt.WatchMrtTrackRequest request,
  ) {
    watched.add(mrt.WatchMrtTrackRequest.fromBuffer(request.writeToBuffer()));
    late StreamController<mrt.MrtTrackState> controller;
    controller = StreamController<mrt.MrtTrackState>(
      onListen: () => controller.add(
        mrt.MrtTrackState(
          trackId: _trackId,
          tripId: _session.tripId,
          carId: _session.carId,
          pathStationIds: _session.pathStationIds,
          pathStationNames: _session.pathStationNames,
          targetIndex: _session.targetIndex,
          currentIndex: _session.currentIndex,
          remainingStops: _session.remainingStops,
          nextStationId: _session.nextStationId,
          nextStationName: _session.nextStationName,
          progress: _session.progress,
          status: 'tracking',
          leadStops: _session.leadStops,
          system: _session.system,
        ),
      ),
      onCancel: () {
        _watches.remove(controller);
      },
    );
    _watches.add(controller);
    return controller.stream;
  }

  @override
  Future<mrt.MrtTrackAck> setTrackPushToken(
    ServiceCall call,
    mrt.SetMrtTrackPushTokenRequest request,
  ) async {
    tokens.add(
      mrt.SetMrtTrackPushTokenRequest.fromBuffer(request.writeToBuffer()),
    );
    return mrt.MrtTrackAck(ok: true);
  }

  @override
  Future<mrt.MrtTrackAck> cancelTrack(
    ServiceCall call,
    mrt.CancelMrtTrackRequest request,
  ) async {
    cancelled.add(
      mrt.CancelMrtTrackRequest.fromBuffer(request.writeToBuffer()),
    );
    return mrt.MrtTrackAck(ok: true);
  }

  @override
  Stream<mrt.Resp_Mrt_eta> eta(ServiceCall call, mrt.Ask_mrt request) =>
      Stream.error(const GrpcError.unimplemented('unexpected ETA request'));

  @override
  Future<mrt.MrtTrackState> createTrack(
    ServiceCall call,
    mrt.CreateMrtTrackRequest request,
  ) async => throw const GrpcError.unimplemented('session must be restored');

  void clearRequests() {
    watched.clear();
    tokens.clear();
    cancelled.clear();
  }

  Future<void> closeWatches() async {
    final pending = List.of(_watches);
    _watches.clear();
    await Future.wait(pending.map((controller) => controller.close()));
  }
}

class _LoopbackAlerts extends alert.Alert_ServiceBase {
  final requested = <AlertSourceKind>[];
  final cities = <String>[];
  final systems = <String>[];
  final _streams = <StreamController<alert.Alert_Msg>>{};

  Stream<alert.Alert_Msg> _open(AlertSourceKind kind, [String? message]) {
    requested.add(kind);
    late StreamController<alert.Alert_Msg> controller;
    controller = StreamController<alert.Alert_Msg>(
      onListen: () => controller.add(
        alert.Alert_Msg(
          items: [
            if (message != null)
              alert.Alert_Item(
                id: 'app-root-${kind.name}',
                routeType: kind.name,
                body: message,
                level: 'red',
              ),
          ],
        ),
      ),
      onCancel: () {
        _streams.remove(controller);
      },
    );
    _streams.add(controller);
    return controller.stream;
  }

  @override
  Stream<alert.Alert_Msg> traAlert(ServiceCall call, alert.Alert_Ask request) =>
      _open(AlertSourceKind.tra, '台鐵 loopback 真實延誤訊息');

  @override
  Stream<alert.Alert_Msg> thsrAlert(
    ServiceCall call,
    alert.Alert_Ask request,
  ) => _open(AlertSourceKind.thsr, '高鐵 loopback 真實延誤訊息');

  @override
  Stream<alert.Alert_Msg> busAlert(
    ServiceCall call,
    alert.Alert_Bus_Ask request,
  ) {
    cities.add(request.city);
    return _open(AlertSourceKind.busAlert);
  }

  @override
  Stream<alert.Alert_Msg> metroAlert(
    ServiceCall call,
    alert.Alert_Metro_Ask request,
  ) {
    systems.add(request.system);
    return _open(AlertSourceKind.metro);
  }

  Future<void> closeStreams() async {
    final pending = List.of(_streams);
    _streams.clear();
    await Future.wait(pending.map((controller) => controller.close()));
  }
}

class _WifiConnectivity extends ConnectivityPlatform {
  @override
  Future<List<ConnectivityResult>> checkConnectivity() async => const [
    ConnectivityResult.wifi,
  ];

  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged =>
      const Stream<List<ConnectivityResult>>.empty();
}

void main() {
  Directory? storage;
  late ConnectivityPlatform originalConnectivity;
  late bool originalInitialized;

  TestWidgetsFlutterBinding.ensureInitialized();
  final service = _LoopbackMrt();
  final alerts = _LoopbackAlerts();
  Server? server;
  RandomAccessFile? lock;
  var locked = false;
  final nativeCalls = <MethodCall>[];
  Future<void> Function()? unmount;

  setUpAll(() async {
    // The global production transport must never dial an unrelated endpoint.
    expect(
      const String.fromEnvironment('GRPC_HOST', defaultValue: '127.0.0.1'),
      '127.0.0.1',
    );
    expect(const int.fromEnvironment('GRPC_PORT', defaultValue: 50051), 50051);
    expect(const bool.fromEnvironment('GRPC_TLS'), isFalse);
    expect(FirebaseGate.enabled, isFalse);

    // Shared across throwaway worktrees. Never unlink the inode: another
    // process may already be waiting on this lock while its suite compiles.
    lock = await File(
      '${Directory.systemTemp.path}/bus-quality-app-root-mrt-50051.lock',
    ).open(mode: FileMode.append);
    await lock!.lock(FileLock.blockingExclusive);
    locked = true;
    server = Server.create(
      services: [service, alerts],
      codecRegistry: CodecRegistry(
        codecs: const [GzipCodec(), IdentityCodec()],
      ),
    );
    // Bind failure is a test failure. No App/GrpcClient has been created yet.
    await server!.serve(address: InternetAddress.loopbackIPv4, port: 50051);
    expect(server!.port, 50051);

    storage = await Directory.systemTemp.createTemp(
      'app-root-native-tracking-',
    );
    Hive.init(storage!.path);
    await HiveStore.init(initBinding: () async {});
  });

  tearDownAll(() async {
    try {
      // Terminate the client before waiting for server-side stream closes:
      // a fake-zone subscription may otherwise hold the controller's done.
      GrpcClient.instance.recycle();
      try {
        await service.closeWatches().timeout(const Duration(seconds: 5));
      } finally {
        try {
          await alerts.closeStreams().timeout(const Duration(seconds: 5));
        } finally {
          // Release the port even if a pending stream fails to close.
          await server?.shutdown().timeout(const Duration(seconds: 5));
        }
      }
    } finally {
      try {
        await Hive.close().timeout(const Duration(seconds: 5));
      } finally {
        try {
          final ownedStorage = storage;
          if (ownedStorage != null && ownedStorage.existsSync()) {
            await ownedStorage.delete(recursive: true);
          }
        } finally {
          try {
            if (locked) await lock!.unlock();
          } finally {
            await lock?.close();
          }
        }
      }
    }
  });

  setUp(() async {
    originalConnectivity = ConnectivityPlatform.instance;
    originalInitialized = App.isInitialized.value;
    AppNetwork.reset();
    ConnectivityPlatform.instance = _WifiConnectivity();
    AlightTrackInboundChannel.reset();
    service.clearRequests();
    alerts.requested.clear();
    alerts.cities.clear();
    alerts.systems.clear();
    nativeCalls.clear();
    FlutterSecureStorage.setMockInitialValues({
      'firebase_install_pair': jsonEncode({
        'id': _installId,
        'secret': 'app-root-native-only-secret',
      }),
    });
    await HiveStore.settings.clear();
    await HiveStore.settings.put('install_id', _installId);
    await HiveStore.settings.put('live_activity_enabled', true);
    await HiveStore.putMrtTrackSession(_session.toJson());
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          nativeCalls.add(call);
          return switch (call.method) {
            'start' => 'app-root-native-card',
            'requestNotificationPermission' || 'notificationsEnabled' => true,
            _ => null,
          };
        });
  });

  tearDown(() async {
    AlightTrackInboundChannel.reset();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
    FlutterSecureStorage.setMockInitialValues({});
    AppForeground.reset();
    AppNetwork.reset();
    ConnectivityPlatform.instance = originalConnectivity;
    App.isInitialized.value = originalInitialized;
  });

  Future<void> until(
    WidgetTester tester,
    bool Function() condition, {
    String Function()? describe,
  }) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) {
        fail(
          'App native tracking condition did not complete within 5 seconds: '
          '${describe?.call() ?? 'condition'}',
        );
      }
      // gRPC's socket handshake also has a short timer in the widget zone.
      await tester.pump(const Duration(milliseconds: 10));
      await tester.runAsync(
        () => Future<void>.delayed(
          const Duration(milliseconds: 10),
        ),
      );
    }
    await tester.pump();
  }

  Future<({MrtTrackBloc metro, JourneySessionBloc journey})> mount(
    WidgetTester tester,
  ) async {
    final controller = AppBootstrapController(
      initHive: () async {},
      initGrpc: () async {},
      initFirebase: () async {},
      initPowerSync: () async {},
    );
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) =>
              const Scaffold(body: Text('app-native-track-probe')),
        ),
      ],
    );
    unmount = () async {
      try {
        await tester.pumpWidget(const SizedBox.shrink());
        GrpcClient.instance.recycle();
        await tester.pump();
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await service.closeWatches().timeout(const Duration(seconds: 5));
          await alerts.closeStreams().timeout(const Duration(seconds: 5));
        });
        await tester.pump();
      } finally {
        router.dispose();
        controller.dispose();
      }
    };
    await controller.start();
    await tester.pumpWidget(App(bootstrap: controller, debugRouter: router));
    await tester.pumpAndSettle();
    final context = tester.element(find.text('app-native-track-probe'));
    final metro = context.read<MrtTrackBloc>();
    final journey = context.read<JourneySessionBloc>();
    await until(
      tester,
      () =>
          metro.state.isActive &&
          service.watched.isNotEmpty &&
          nativeCalls.any((call) => call.method == 'start'),
      describe: () =>
          'metro=${metro.state}, watch=${service.watched.length}, '
          'native=${nativeCalls.map((call) => call.method).toList()}',
    );
    expect(metro.state.session, _session);
    expect(service.watched.single.trackId, _trackId);
    expect(journey.state.phase, JourneyPhase.idle);
    return (metro: metro, journey: journey);
  }

  Future<void> fire(WidgetTester tester, String method, [Object? args]) async {
    await tester.runAsync(() async {
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        _channel.name,
        const StandardMethodCodec().encodeMethodCall(MethodCall(method, args)),
        (_) {},
      );
    });
    await tester.pump();
  }

  void nativeTest(
    String description,
    Future<void> Function(WidgetTester) body,
  ) {
    testWidgets(description, (tester) async {
      try {
        await body(tester);
      } finally {
        final cleanup = unmount;
        unmount = null;
        try {
          await cleanup?.call();
        } finally {
          var cleared = false;
          Object? clearError;
          StackTrace? clearStack;
          // Hive's prior unawaited persist must finish while its fake zone is
          // still being pumped, before tearDownAll closes the storage files.
          await tester.runAsync(() async {
            unawaited(
              HiveStore.settings.clear().then<void>(
                (_) => cleared = true,
                onError: (Object error, StackTrace stack) {
                  clearError = error;
                  clearStack = stack;
                  cleared = true;
                },
              ),
            );
          });
          await until(tester, () => cleared);
          if (clearError != null) {
            Error.throwWithStackTrace(clearError!, clearStack!);
          }
          await tester.pump();
        }
      }
    });
  }

  nativeTest('native push token reaches the restored App MRT session RPC', (
    tester,
  ) async {
    final blocs = await mount(tester);
    const token = '0123456789abcdef-app-root-token';
    await fire(tester, 'onPushToken', token);
    await until(tester, () => service.tokens.isNotEmpty);

    final request = service.tokens.single;
    expect(request.trackId, _trackId);
    expect(request.pushToken, token);
    expect(request.installId, _installId);
    expect(blocs.metro.state.session, _session);
    expect(blocs.journey.state.phase, JourneyPhase.idle);
    expect(service.cancelled, isEmpty);
  });

  nativeTest('native cancel reaches both globally provided active owners', (
    tester,
  ) async {
    final blocs = await mount(tester);
    const leg = JourneyLeg(
      kind: JourneyLegKind.bus,
      routeLabel: '307',
      boardStop: '台北車站',
      alightStop: '市政府',
      stopNames: ['台北車站', '市政府'],
      identity: PlanIdentity.empty(),
      leadingWalkMinutes: 0,
      scheduledDeparture: null,
      scheduledArrival: null,
      boardLocation: PlanPoint(lat: 25.0478, lng: 121.5170),
      stopLocations: [PlanPoint(lat: 25.0412, lng: 121.5650)],
    );
    blocs.journey.add(const JourneyStarted(legs: [leg]));
    await until(
      tester,
      () =>
          blocs.journey.state.phase == JourneyPhase.waiting &&
          nativeCalls.where((call) => call.method == 'start').length == 2,
    );
    expect(blocs.metro.state.isActive, isTrue);

    await fire(tester, 'onCancelTrack');
    await until(
      tester,
      () =>
          blocs.journey.state.phase == JourneyPhase.done &&
          blocs.metro.state.session == null &&
          service.cancelled.isNotEmpty,
    );
    final request = service.cancelled.single;
    expect(request.trackId, _trackId);
    expect(request.installId, _installId);
    expect(HiveStore.mrtTrackSession, isNull);
    expect(service.tokens, isEmpty);
  });
  nativeTest('ready App starts real TRA and THSR alerts after its delay', (
    tester,
  ) async {
    await mount(tester);
    final context = tester.element(find.text('app-native-track-probe'));
    final bloc = context.read<AlertBloc>();
    expect(alerts.requested, isEmpty);
    expect(bloc.state.activeAlerts, isEmpty);

    // Advance the production shell timer, not an AlertStarted event injected
    // by the test. The receiver must decode actual native streaming frames.
    await tester.pump(const Duration(seconds: 2));
    await until(
      tester,
      () =>
          alerts.requested.length == 4 && bloc.state.visibleAlerts.length == 2,
    );
    expect(
      alerts.requested,
      unorderedEquals([
        AlertSourceKind.tra,
        AlertSourceKind.thsr,
        AlertSourceKind.metro,
        AlertSourceKind.busAlert,
      ]),
    );
    expect(alerts.systems, ['TRTC']);
    expect(alerts.cities, ['Taipei']);
    final received = bloc.state.visibleAlerts;
    expect(
      received.map((row) => row.message),
      unorderedEquals([
        '台鐵 loopback 真實延誤訊息',
        '高鐵 loopback 真實延誤訊息',
      ]),
    );
    expect(received.every((row) => row.level == AlertSeverity.red), isTrue);
    expect(
      received.map((row) => row.source),
      unorderedEquals([
        const AlertSource(AlertSourceKind.tra),
        const AlertSource(AlertSourceKind.thsr),
      ]),
    );
    expect(bloc.state.error, isNull);
  });
}
