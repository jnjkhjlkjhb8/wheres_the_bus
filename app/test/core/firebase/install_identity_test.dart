import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:wheres_the_bus/core/firebase/install_identity.dart';

void main() {
  late Directory directory;
  late Box<dynamic> settings;
  late Map<String, String> secure;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('install_identity_test');
    Hive.init(directory.path);
    settings = await Hive.openBox<dynamic>('settings');
    secure = <String, String>{};
  });

  tearDown(() async {
    await settings.close();
    await directory.delete(recursive: true);
  });

  test(
    'rotates id and secret together after backup omits secure storage',
    () async {
      await settings.put('install_id', 'restored-id');
      final pair = await InstallIdentity.getOrCreatePair(
        settings: settings,
        secureRead: (key) async => secure[key],
        secureWrite: (key, value) async => secure[key] = value,
      );

      expect(pair.$1, isNot('restored-id'));
      expect(pair.$2, secure['firebase_install_secret']);
      expect(settings.get('install_id'), pair.$1);
    },
  );

  test('keeps a complete restored pair stable', () async {
    await settings.put('install_id', 'restored-id');
    secure['firebase_install_secret'] = 'restored-secret';

    final pair = await InstallIdentity.getOrCreatePair(
      settings: settings,
      secureRead: (key) async => secure[key],
      secureWrite: (key, value) async => secure[key] = value,
    );

    expect(pair, ('restored-id', 'restored-secret'));
  });

  test('repairs the mirrored id from the durable secure pair', () async {
    await settings.put('install_id', 'stale-id');
    secure['firebase_install_pair'] =
        '{"id":"canonical-id","secret":"canonical-secret"}';

    final pair = await InstallIdentity.getOrCreatePair(
      settings: settings,
      secureRead: (key) async => secure[key],
      secureWrite: (key, value) async => secure[key] = value,
    );

    expect(pair, ('canonical-id', 'canonical-secret'));
    expect(settings.get('install_id'), 'canonical-id');
  });

  test(
    'a canonical pair avoids legacy reads and writes when the mirror matches',
    () async {
      await settings.put('install_id', 'canonical-id');
      secure['firebase_install_pair'] =
          '{"id":"canonical-id","secret":"canonical-secret"}';
      final reads = <String>[];
      final writes = <String>[];
      final pair = await InstallIdentity.getOrCreatePair(
        settings: settings,
        secureRead: (key) async {
          reads.add(key);
          return secure[key];
        },
        secureWrite: (key, value) async => writes.add(key),
      );
      expect(pair, ('canonical-id', 'canonical-secret'));
      expect(reads, ['firebase_install_pair']);
      expect(writes, isEmpty);
    },
  );

  for (final invalid in [
    'not json',
    '[]',
    'null',
    '{}',
    '{"id":1,"secret":"secret"}',
    '{"id":"","secret":"secret"}',
    '{"id":"id","secret":1}',
    '{"id":"id","secret":""}',
  ]) {
    test(
      'invalid durable pair $invalid falls back to the complete legacy pair',
      () async {
        await settings.put('install_id', 'legacy-id');
        await settings.put('install_secret', 'legacy-secret');
        secure['firebase_install_pair'] = invalid;
        final pair = await InstallIdentity.getOrCreatePair(
          settings: settings,
          secureRead: (key) async => secure[key],
          secureWrite: (key, value) async => secure[key] = value,
        );
        expect(pair, ('legacy-id', 'legacy-secret'));
        expect(jsonDecode(secure['firebase_install_pair']!), {
          'id': 'legacy-id',
          'secret': 'legacy-secret',
        });
        expect(secure['firebase_install_secret'], 'legacy-secret');
        expect(settings.containsKey('install_secret'), isFalse);
      },
    );
  }

  test(
    'secure legacy secret wins over the Hive secret and removes it',
    () async {
      await settings.put('install_id', 'id');
      await settings.put('install_secret', 'stale-secret');
      secure['firebase_install_secret'] = 'secure-secret';
      final writes = <String>[];
      final pair = await InstallIdentity.getOrCreatePair(
        settings: settings,
        secureRead: (key) async => secure[key],
        secureWrite: (key, value) async {
          writes.add(key);
          secure[key] = value;
        },
      );
      expect(pair, ('id', 'secure-secret'));
      expect(writes, ['firebase_install_pair']);
      expect(settings.containsKey('install_secret'), isFalse);
    },
  );

  for (final id in [null, '', 42]) {
    test(
      'invalid mirrored id $id rotates both values despite a legacy secret',
      () async {
        await settings.put('install_id', id);
        await settings.put('install_secret', 'legacy-secret');
        secure['firebase_install_secret'] = 'secure-secret';
        final pair = await InstallIdentity.getOrCreatePair(
          settings: settings,
          secureRead: (key) async => secure[key],
          secureWrite: (key, value) async => secure[key] = value,
        );
        expect(
          pair.$1,
          matches(
            RegExp(
              '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-'
              r'[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
            ),
          ),
        );
        expect(pair.$2, isNot('secure-secret'));
        expect(pair.$2, matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));
        expect(base64Url.decode(base64Url.normalize(pair.$2)), hasLength(32));
        expect(settings.get('install_id'), pair.$1);
        expect(settings.containsKey('install_secret'), isFalse);
        expect(secure['firebase_install_secret'], pair.$2);
      },
    );
  }

  test(
    'concurrent callers share creation and a failed write can be retried',
    () async {
      final reading = Completer<String?>();
      var reads = 0;
      Future<String?> read(String key) async {
        reads++;
        if (key == 'firebase_install_pair') return reading.future;
        return null;
      }

      Future<void> write(String key, String value) async {
        secure[key] = value;
      }

      final first = InstallIdentity.getOrCreatePair(
        settings: settings,
        secureRead: read,
        secureWrite: write,
      );
      final second = InstallIdentity.getOrCreatePair(
        settings: settings,
        secureRead: (_) async =>
            throw StateError('must share the pending read'),
        secureWrite: write,
      );
      final id = InstallIdentity.getOrCreate(settings: settings);
      final secret = InstallIdentity.getOrCreateSecret(settings: settings);
      reading.complete(null);
      final pair = await first;
      expect(pair, await second);
      expect(await id, pair.$1);
      expect(await secret, pair.$2);
      expect(reads, 2);

      secure.clear();
      await settings.clear();
      await expectLater(
        InstallIdentity.getOrCreatePair(
          settings: settings,
          secureRead: (_) async => null,
          secureWrite: (_, _) async => throw StateError('storage unavailable'),
        ),
        throwsStateError,
      );
      final retried = await InstallIdentity.getOrCreatePair(
        settings: settings,
        secureRead: (key) async => secure[key],
        secureWrite: write,
      );
      expect(retried.$2, secure['firebase_install_secret']);
    },
  );
}
