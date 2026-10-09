import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/core/grpc/grpc_client.dart';
import 'package:wheres_the_bus/core/lifecycle/app_foreground.dart';

void main() {
  group('GrpcClient.validateConfig', () {
    test('allows loopback + insecure on dev', () {
      expect(
        () => GrpcClient.validateConfig(
          appEnv: 'dev',
          host: '127.0.0.1',
          tls: false,
        ),
        returnsNormally,
      );
    });

    test('rejects loopback host on production', () {
      expect(
        () => GrpcClient.validateConfig(
          appEnv: 'production',
          host: '127.0.0.1',
          tls: true,
        ),
        throwsStateError,
      );
    });

    test('rejects empty host on staging', () {
      expect(
        () => GrpcClient.validateConfig(
          appEnv: 'staging',
          host: '',
          tls: true,
        ),
        throwsStateError,
      );
    });

    test('rejects insecure TLS on production even with a real host', () {
      expect(
        () => GrpcClient.validateConfig(
          appEnv: 'production',
          host: 'api.example.com',
          tls: false,
        ),
        throwsStateError,
      );
    });

    test('accepts a real host with TLS on staging', () {
      expect(
        () => GrpcClient.validateConfig(
          appEnv: 'staging',
          host: 'staging.example.com',
          tls: true,
        ),
        returnsNormally,
      );
    });

    test('allows loopback + insecure on test flavor', () {
      expect(
        () => GrpcClient.validateConfig(
          appEnv: 'test',
          host: 'localhost',
          tls: false,
        ),
        returnsNormally,
      );
    });

    test('unset APP_ENV (empty string) gets strict validation', () {
      expect(
        () => GrpcClient.validateConfig(
          appEnv: '',
          host: '127.0.0.1',
          tls: false,
        ),
        throwsStateError,
      );
    });

    test("misspelled 'prod' gets strict validation", () {
      expect(
        () => GrpcClient.validateConfig(
          appEnv: 'prod',
          host: 'localhost',
          tls: true,
        ),
        throwsStateError,
      );
    });

    test("mixed-case 'Production' gets strict validation", () {
      expect(
        () => GrpcClient.validateConfig(
          appEnv: 'Production',
          host: 'api.example.com',
          tls: false,
        ),
        throwsStateError,
      );
    });

    test('unknown env with a real host and TLS still passes', () {
      expect(
        () => GrpcClient.validateConfig(
          appEnv: 'prod',
          host: 'api.example.com',
          tls: true,
        ),
        returnsNormally,
      );
    });
  });

  group('channel lifecycle', () {
    // Reading any service client is what forces the channel into existence.
    void openChannel() => GrpcClient.instance.busRoute;
    int generation() => GrpcClient.instance.channelGeneration;

    test('recycle drops the channel and the next use builds a new one', () {
      openChannel();
      final built = generation();

      GrpcClient.instance.recycle();
      openChannel();

      expect(generation(), built + 1);
    });

    test('coming back to the foreground recycles the channel', () {
      openChannel();
      final built = generation();

      GrpcClient.handleForeground();

      expect(
        generation(),
        built + 1,
        reason: 'warmConnection must dial a fresh channel, not the dead one',
      );
    });

    test('going to the background leaves the channel alone', () {
      openChannel();
      final built = generation();

      AppForeground.value.value = false;
      addTearDown(() => AppForeground.value.value = true);
      GrpcClient.handleForeground();

      expect(generation(), built);
    });
  });
}
