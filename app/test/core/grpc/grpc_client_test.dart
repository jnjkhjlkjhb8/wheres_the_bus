import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart';
import 'package:wheres_the_bus/core/grpc/grpc_client.dart';
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

class _PolicyBike extends Bike_ServiceBase {
  final metadata = <Map<String, String>>[];
  final deadlines = <Duration?>[];

  @override
  Future<Bike_static> static(ServiceCall call, Bike_request request) async {
    metadata.add(Map<String, String>.of(call.clientMetadata!));
    deadlines.add(call.deadline?.difference(DateTime.now()));
    return Bike_static(
      stationUID: request.stationUID,
      name: 'contract response',
    );
  }

  @override
  Stream<Resp_Bike_eta> eta(ServiceCall call, Bike_request request) =>
      const Stream<Resp_Bike_eta>.empty();
}

void main() {
  setUp(GrpcClient.instance.shutdown);
  tearDown(GrpcClient.instance.shutdown);

  test(
    'closing or recycling an unused client does not create a channel',
    () async {
      final generation = GrpcClient.instance.channelGeneration;
      await GrpcClient.instance.shutdown();
      GrpcClient.instance.recycle();
      expect(GrpcClient.instance.channelGeneration, generation);
      expect(GrpcClient.instance.busRoute, isA<Client>());
      expect(GrpcClient.instance.channelGeneration, generation + 1);
    },
  );

  test('warming creates one shared channel for all service clients', () {
    final generation = GrpcClient.instance.channelGeneration;
    GrpcClient.warmConnection();
    expect(GrpcClient.instance.channelGeneration, generation + 1);
    GrpcClient.warmConnection();
    final clients = <Client>[
      GrpcClient.instance.busRoute,
      GrpcClient.instance.busStation,
      GrpcClient.instance.bike,
      GrpcClient.instance.mrt,
      GrpcClient.instance.traTimetable,
      GrpcClient.instance.traDetain,
      GrpcClient.instance.thsr,
      GrpcClient.instance.thsrDetain,
      GrpcClient.instance.alert,
      GrpcClient.instance.near,
      GrpcClient.instance.maas,
      GrpcClient.instance.firebase,
      GrpcClient.instance.feedback,
    ];
    expect(clients, hasLength(13));
    expect(GrpcClient.instance.channelGeneration, generation + 1);
  });

  test('shutdown releases the shared channel and remains idempotent', () async {
    GrpcClient.warmConnection();
    final generation = GrpcClient.instance.channelGeneration;
    await GrpcClient.instance.shutdown();
    await GrpcClient.instance.shutdown();
    expect(GrpcClient.instance.channelGeneration, generation);
    expect(GrpcClient.instance.feedback, isA<Client>());
    expect(GrpcClient.instance.channelGeneration, generation + 1);
    GrpcClient.warmConnection();
    expect(GrpcClient.instance.channelGeneration, generation + 1);
  });

  test('recycle defers replacement until the next warm request', () {
    expect(GrpcClient.instance.busRoute, isA<Client>());
    final generation = GrpcClient.instance.channelGeneration;
    GrpcClient.instance.recycle();
    expect(GrpcClient.instance.channelGeneration, generation);
    GrpcClient.warmConnection();
    expect(GrpcClient.instance.channelGeneration, generation + 1);
    GrpcClient.warmConnection();
    expect(GrpcClient.instance.channelGeneration, generation + 1);
  });

  test(
    'default unconfigured startup rejects loopback before creating a channel',
    () async {
      final generation = GrpcClient.instance.channelGeneration;
      await expectLater(
        GrpcClient.init(),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'configuration field',
            contains('GRPC_HOST'),
          ),
        ),
      );
      expect(GrpcClient.instance.channelGeneration, generation);
    },
  );

  group('public configuration safety policy', () {
    for (final environment in ['dev', 'test']) {
      test('$environment permits local endpoints with either TLS setting', () {
        for (final host in ['', 'localhost', '127.0.0.1']) {
          for (final tls in [false, true]) {
            expect(
              () => GrpcClient.validateConfig(
                appEnv: environment,
                host: host,
                tls: tls,
              ),
              returnsNormally,
            );
          }
        }
      });
    }

    for (final environment in [
      '',
      'production',
      'staging',
      'prod',
      'Production',
    ]) {
      test('$environment rejects every local endpoint regardless of TLS', () {
        for (final host in ['', 'localhost', '127.0.0.1']) {
          for (final tls in [false, true]) {
            expect(
              () => GrpcClient.validateConfig(
                appEnv: environment,
                host: host,
                tls: tls,
              ),
              throwsA(
                isA<StateError>().having(
                  (error) => error.message,
                  'configuration field',
                  contains('GRPC_HOST'),
                ),
              ),
            );
          }
        }
      });
      test('$environment requires TLS for a remote endpoint', () {
        expect(
          () => GrpcClient.validateConfig(
            appEnv: environment,
            host: 'api.example.com',
            tls: false,
          ),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'configuration field',
              contains('GRPC_TLS'),
            ),
          ),
        );
        expect(
          () => GrpcClient.validateConfig(
            appEnv: environment,
            host: 'api.example.com',
            tls: true,
          ),
          returnsNormally,
        );
      });
    }
  });

  test(
    'channel options observe existing transport without creating one',
    () async {
      final client = GrpcClient.instance;
      final generation = client.channelGeneration;
      expect(client.channelOptions, isNull);
      expect(client.channelGeneration, generation);
      expect(client.busRoute, isA<Client>());
      final first = client.channelOptions!;
      _expectChannelPolicy(first, secure: false);
      expect(client.feedback, isA<Client>());
      expect(client.channelOptions, same(first));
      client.recycle();
      expect(client.channelOptions, isNull);
      expect(client.channelGeneration, generation + 1);
      expect(client.bike, isA<Client>());
      final replacement = client.channelOptions!;
      expect(replacement, isNot(same(first)));
      _expectChannelPolicy(replacement, secure: false);
      await client.shutdown();
      expect(client.channelOptions, isNull);
      await client.shutdown();
      expect(client.channelGeneration, generation + 2);
    },
  );

  test(
    'generated RPC applies the assembled deadline and compression chain',
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      expect(
        const String.fromEnvironment('GRPC_HOST', defaultValue: '127.0.0.1'),
        '127.0.0.1',
      );
      expect(
        const int.fromEnvironment('GRPC_PORT', defaultValue: 50051),
        50051,
      );
      expect(const bool.fromEnvironment('GRPC_TLS'), isFalse);
      final service = _PolicyBike();
      RandomAccessFile? lock;
      var locked = false;
      Server? server;
      final calls = <ResponseFuture<Bike_static>>[];
      try {
        // Keep the shared inode: another worktree may already be waiting
        // to bind this endpoint.
        lock = await File(
          '${Directory.systemTemp.path}/bus-quality-app-root-mrt-50051.lock',
        ).open(mode: FileMode.append);
        await lock.lock(FileLock.blockingExclusive);
        locked = true;
        server = Server.create(
          services: [service],
          codecRegistry: CodecRegistry(
            codecs: const [GzipCodec(), IdentityCodec()],
          ),
        );
        await server.serve(address: InternetAddress.loopbackIPv4, port: 50051);
        expect(server.port, 50051);

        final defaultCall = GrpcClient.instance.bike.static(
          Bike_request(stationUID: 'default'),
          options: CallOptions(metadata: {'x-contract': 'default'}),
        );
        calls.add(defaultCall);
        final response = await defaultCall.timeout(const Duration(seconds: 5));
        expect(response.stationUID, 'default');
        expect(response.name, 'contract response');
        expect(service.metadata.single['x-contract'], 'default');
        expect(service.metadata.single['grpc-encoding'], 'gzip');
        expect(service.deadlines.single, isNotNull);
        expect(
          service.deadlines.single!.inMilliseconds,
          inInclusiveRange(8000, 10000),
        );

        final overrideCall = GrpcClient.instance.bike.static(
          Bike_request(stationUID: 'override'),
          options: CallOptions(
            timeout: const Duration(seconds: 2),
            compression: const IdentityCodec(),
            metadata: {'x-contract': 'override'},
          ),
        );
        calls.add(overrideCall);
        expect(
          (await overrideCall.timeout(const Duration(seconds: 5))).stationUID,
          'override',
        );
        expect(service.metadata, hasLength(2));
        expect(service.metadata.last['x-contract'], 'override');
        expect(service.metadata.last['grpc-encoding'], 'identity');
        expect(service.deadlines.last, isNotNull);
        expect(
          service.deadlines.last!.inMilliseconds,
          inInclusiveRange(1, 2000),
        );
      } finally {
        try {
          await Future.wait(
            calls.map((call) => call.cancel()),
          ).timeout(const Duration(seconds: 5));
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
                await lock?.close();
              }
            }
          }
        }
      }
    },
  );
}
