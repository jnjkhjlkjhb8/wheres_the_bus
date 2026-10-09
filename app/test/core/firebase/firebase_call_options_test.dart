import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/core/firebase/firebase_call_options.dart';

void main() {
  group('FirebaseCallOptions.build', () {
    test('degrades to no appcheck header when getToken throws', () async {
      final options = await FirebaseCallOptions.build(
        enabled: true,
        tls: true,
        tokenLoader: () async => throw StateError('App attestation failed'),
        installIdLoader: () async => 'install-id',
        installSecretLoader: () async => 'install-secret',
      );

      expect(options.metadata['x-install-id'], 'install-id');
      expect(options.metadata['x-install-secret'], 'install-secret');
      expect(options.metadata.containsKey('x-firebase-appcheck'), isFalse);
    });

    test('attaches appcheck header when token is available', () async {
      final options = await FirebaseCallOptions.build(
        enabled: true,
        tls: true,
        tokenLoader: () async => 'appcheck-token',
        installIdLoader: () async => 'install-id',
        installSecretLoader: () async => 'install-secret',
      );

      expect(options.metadata['x-firebase-appcheck'], 'appcheck-token');
    });
  });
}
