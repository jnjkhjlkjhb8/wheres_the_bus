import 'dart:async';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart';
import 'package:wheres_the_bus/core/firebase/firebase_gate.dart';
import 'package:wheres_the_bus/core/grpc/grpc_client.dart';
import 'package:wheres_the_bus/core/lifecycle/app_foreground.dart';
import 'package:wheres_the_bus/data/generated/bike.pbgrpc.dart';

void _expectChannelPolicy(ChannelOptions options, {required bool secure}) {
  expect(options.keepAlive.pingInterval, const Duration(seconds: 60));
  expect(options.keepAlive.pingInterval, greaterThan(Duration.zero));
  expect(options.keepAlive.timeout, const Duration(seconds: 10));
  expect(options.keepAlive.timeout, greaterThan(Duration.zero));
  expect(options.connectTimeout, const Duration(seconds: 10));
  expect(options.credentials.isSecure, secure);
  expect(options.credentials.onBadCertificate, isNull);
  expect(options.credentials.authority, isNull);
  expect(options.credentials.securityContext, secure ? isNotNull : isNull);
  final registry = options.codecRegistry!;
  expect(
    registry.supportedEncodings.split(','),
    unorderedEquals(['gzip', 'identity']),
  );
  for (final encoding in ['gzip', 'identity']) {
    final codec = registry.lookup(encoding)!;
    final payload = List<int>.generate(256, (index) => index);
    expect(codec.decompress(codec.compress(payload)), payload);
  }
}

class _Core extends MockFirebaseApp {
  @override
  Future<List<CoreInitializeResponse>> initializeCore() async => [];

  @override
  Future<CoreInitializeResponse> initializeApp(
    String name,
    CoreFirebaseOptions options,
  ) async => CoreInitializeResponse(
    name: name,
    options: options,
    pluginConstants: {
      'plugins.flutter.io/firebase_crashlytics': {
        'isCrashlyticsCollectionEnabled': true,
      },
    },
  );
}

class _TlsRejectedBike extends Bike_ServiceBase {
  int applicationCalls = 0;

  @override
  Future<Bike_static> static(ServiceCall call, Bike_request request) async {
    applicationCalls++;
    return Bike_static(stationUID: request.stationUID);
  }

  @override
  Stream<Resp_Bike_eta> eta(ServiceCall call, Bike_request request) {
    applicationCalls++;
    return const Stream<Resp_Bike_eta>.empty();
  }
}

void main() {
  test(
    'TLS startup protects early use and observes each resume once',
    () async {
      final foreground = AppForeground.value.value;
      try {
        await GrpcClient.instance.shutdown();
        expect(
          () => GrpcClient.instance.busRoute,
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'required startup',
              contains('GrpcClient.init()'),
            ),
          ),
        );

        await GrpcClient.init();
        final generation = GrpcClient.instance.channelGeneration;
        expect(GrpcClient.instance.busRoute, isA<Client>());
        await GrpcClient.init();
        GrpcClient.warmConnection();
        expect(GrpcClient.instance.channelGeneration, generation);

        AppForeground.value.value = false;
        expect(GrpcClient.instance.channelGeneration, generation);
        AppForeground.value.value = true;
        expect(GrpcClient.instance.channelGeneration, generation + 1);
        await GrpcClient.instance.shutdown();
        expect(GrpcClient.instance.feedback, isA<Client>());
        expect(GrpcClient.instance.channelGeneration, generation + 2);
      } finally {
        try {
          AppForeground.value.value = foreground;
        } finally {
          await GrpcClient.instance.shutdown();
        }
      }
    },
  );

  test(
    'TLS channel options retain security through recycle and shutdown',
    () async {
      final client = GrpcClient.instance;
      try {
        await client.shutdown();
        final generation = client.channelGeneration;
        expect(client.channelOptions, isNull);
        expect(client.channelGeneration, generation);
        await GrpcClient.init();
        final first = client.channelOptions!;
        _expectChannelPolicy(first, secure: true);
        expect(client.busRoute, isA<Client>());
        expect(client.channelOptions, same(first));
        client.recycle();
        expect(client.channelOptions, isNull);
        expect(client.channelGeneration, generation + 1);
        await GrpcClient.init();
        final replacement = client.channelOptions!;
        expect(replacement, isNot(same(first)));
        _expectChannelPolicy(replacement, secure: true);
        await client.shutdown();
        expect(client.channelOptions, isNull);
        await client.shutdown();
        expect(client.channelGeneration, generation + 2);
      } finally {
        await client.shutdown();
      }
    },
  );

  test(
    'generated TLS RPC reports one caller failure without plaintext execution',
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      expect(FirebaseGate.enabled, isTrue);
      expect(
        const String.fromEnvironment('GRPC_HOST', defaultValue: '127.0.0.1'),
        '127.0.0.1',
      );
      expect(
        const int.fromEnvironment('GRPC_PORT', defaultValue: 50051),
        50051,
      );
      expect(const bool.fromEnvironment('GRPC_TLS'), isTrue);
      expect(Firebase.apps, isEmpty);
      const channel = MethodChannel('plugins.flutter.io/firebase_crashlytics');
      const pigeon = 'dev.flutter.pigeon.firebase_core_platform_interface';
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      for (final name in [
        channel.name,
        '$pigeon.FirebaseCoreHostApi.initializeCore',
        '$pigeon.FirebaseCoreHostApi.initializeApp',
        '$pigeon.FirebaseCoreHostApi.optionsFromResource',
      ]) {
        expect(messenger.checkMockMessageHandler(name, null), isTrue);
      }
      final reports = <MethodCall>[];
      final recorded = Completer<void>();
      final service = _TlsRejectedBike();
      RandomAccessFile? lock;
      var locked = false;
      Server? server;
      ResponseFuture<Bike_static>? rpc;
      var coreInstalled = false;
      var crashInstalled = false;
      try {
        TestFirebaseCoreHostApi.setUp(_Core());
        coreInstalled = true;
        messenger.setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'Crashlytics#recordError') {
            reports.add(call);
            if (!recorded.isCompleted) recorded.complete();
          }
          return null;
        });
        crashInstalled = true;
        await Firebase.initializeApp(
          options: const FirebaseOptions(
            apiKey: 'quality-test-key',
            appId: '1:1:android:grpc-chain-contract',
            messagingSenderId: '1',
            projectId: 'quality-test-project',
          ),
        );
        lock = await File(
          '${Directory.systemTemp.path}/bus-quality-app-root-mrt-50051.lock',
        ).open(mode: FileMode.append);
        await lock.lock(FileLock.blockingExclusive);
        locked = true;
        // Plaintext exposes accidental TLS bypass through an executed RPC.
        server = Server.create(services: [service]);
        await server.serve(address: InternetAddress.loopbackIPv4, port: 50051);
        expect(server.port, 50051);
        await GrpcClient.init();
        _expectChannelPolicy(GrpcClient.instance.channelOptions!, secure: true);
        rpc = GrpcClient.instance.bike.static(
          Bike_request(stationUID: 'must-not-execute'),
          options: CallOptions(timeout: const Duration(seconds: 2)),
        );
        Object? callerError;
        try {
          await rpc.timeout(const Duration(seconds: 5));
        } on Object catch (error) {
          callerError = error;
        }
        expect(callerError, isA<GrpcError>());
        await recorded.future.timeout(
          const Duration(seconds: 5),
          onTimeout: () {},
        );
        await Future<void>.delayed(Duration.zero);
        expect(service.applicationCalls, 0);
        expect(reports, hasLength(1));
        final arguments = reports.single.arguments as Map<Object?, Object?>;
        expect(arguments['exception'], callerError.toString());
        expect(arguments['fatal'], isFalse);
      } finally {
        try {
          await rpc?.cancel().timeout(const Duration(seconds: 5));
        } finally {
          try {
            await GrpcClient.instance.shutdown().timeout(
              const Duration(seconds: 5),
            );
          } finally {
            try {
              await server?.shutdown().timeout(const Duration(seconds: 5));
            } finally {
              try {
                if (locked) await lock!.unlock();
              } finally {
                try {
                  await lock?.close();
                } finally {
                  try {
                    if (crashInstalled) {
                      messenger.setMockMethodCallHandler(channel, null);
                    }
                  } finally {
                    if (coreInstalled) TestFirebaseCoreHostApi.setUp(null);
                  }
                }
              }
            }
          }
        }
      }
    },
  );
}
