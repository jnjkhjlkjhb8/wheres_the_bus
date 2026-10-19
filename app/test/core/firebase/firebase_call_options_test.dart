import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:wheres_the_bus/core/firebase/firebase_call_options.dart';

void main() {
  group('FirebaseCallOptions.build', () {
    test('Firebase registration refuses plaintext transport', () async {
      await expectLater(
        FirebaseCallOptions.build(enabled: true),
        throwsStateError,
      );
    });

    test('disabled Firebase skips credentials and attestation', () async {
      final options = await FirebaseCallOptions.build(
        tokenLoader: () => throw StateError('should not request attestation'),
        installIdLoader: () => throw StateError('should not load identity'),
      );
      expect(options.metadata, isEmpty);
    });

    test('missing installation credentials fail before attestation', () async {
      var attestationRequests = 0;
      for (final pair in [('', 'secret'), ('id', '')]) {
        await expectLater(
          FirebaseCallOptions.build(
            enabled: true,
            tls: true,
            installIdLoader: () async => pair.$1,
            installSecretLoader: () async => pair.$2,
            tokenLoader: () async {
              attestationRequests++;
              return 'appcheck-token';
            },
          ),
          throwsStateError,
        );
        expect(attestationRequests, 0);
      }
    });

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

    for (final token in <String?>[null, '']) {
      final label = token == null ? 'null' : 'empty';
      test('$label attestation preserves installation metadata', () async {
        final options = await FirebaseCallOptions.build(
          enabled: true,
          tls: true,
          tokenLoader: () async => token,
          installIdLoader: () async => 'install-id',
          installSecretLoader: () async => 'install-secret',
        );

        expect(options.metadata, {
          'x-install-id': 'install-id',
          'x-install-secret': 'install-secret',
        });
      });
    }

    group('stored installation credentials', () {
      const channel = MethodChannel(
        'plugins.it_nomads.com/flutter_secure_storage',
      );
      late Box<dynamic> settings;
      late Map<String, String> secure;

      setUp(() async {
        TestWidgetsFlutterBinding.ensureInitialized();
        final directory = await Directory.systemTemp.createTemp(
          'firebase_call_options_test',
        );
        Box<dynamic>? opened;
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        var handlerInstalled = false;
        addTearDown(() async {
          try {
            if (handlerInstalled) {
              messenger.setMockMethodCallHandler(channel, null);
            }
          } finally {
            try {
              await opened?.close();
            } finally {
              await directory.delete(recursive: true);
            }
          }
        });
        Hive.init(directory.path);
        final box = await Hive.openBox<dynamic>('settings');
        opened = box;
        settings = box;
        await settings.put('install_id', 'stored-id');
        secure = {
          'firebase_install_pair': jsonEncode({
            'id': 'stored-id',
            'secret': 'stored-secret',
          }),
        };
        expect(messenger.checkMockMessageHandler(channel.name, null), isTrue);
        messenger.setMockMethodCallHandler(channel, (call) async {
          final arguments = call.arguments as Map<Object?, Object?>;
          if (call.method == 'read') return secure[arguments['key']];
          if (call.method == 'write') {
            final key = arguments['key'];
            final value = arguments['value'];
            if (key is! String || value is! String) {
              throw StateError('invalid secure storage write');
            }
            secure[key] = value;
          }
          return null;
        });
        handlerInstalled = true;
      });

      test('default loaders preserve the durable installation pair', () async {
        final options = await FirebaseCallOptions.build(
          enabled: true,
          tls: true,
          tokenLoader: () async => null,
        );

        expect(options.metadata, {
          'x-install-id': 'stored-id',
          'x-install-secret': 'stored-secret',
        });
        expect(settings.get('install_id'), 'stored-id');
      });

      test('an id override keeps the stored secret fallback', () async {
        final requests = <String>[];
        final options = await FirebaseCallOptions.build(
          enabled: true,
          tls: true,
          tokenLoader: () async {
            requests.add('attestation');
            return null;
          },
          installIdLoader: () async {
            requests.add('id');
            return 'provided-id';
          },
        );

        expect(options.metadata, {
          'x-install-id': 'provided-id',
          'x-install-secret': 'stored-secret',
        });
        expect(requests, ['id', 'attestation']);
      });

      test('a secret override keeps the stored id fallback', () async {
        final requests = <String>[];
        final options = await FirebaseCallOptions.build(
          enabled: true,
          tls: true,
          tokenLoader: () async {
            requests.add('attestation');
            return null;
          },
          installSecretLoader: () async {
            requests.add('secret');
            return 'provided-secret';
          },
        );

        expect(options.metadata, {
          'x-install-id': 'stored-id',
          'x-install-secret': 'provided-secret',
        });
        expect(requests, ['secret', 'attestation']);
      });
    });
  });
}
