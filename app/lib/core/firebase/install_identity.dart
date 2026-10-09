import 'dart:convert';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_ce/hive.dart';
import 'package:uuid/uuid.dart';
import 'package:wheres_the_bus/core/storage/hive_store.dart';

class InstallIdentity {
  InstallIdentity._();

  static const _key = 'install_id';
  static const _secretKey = 'install_secret';
  static const _secureSecretKey = 'firebase_install_secret';
  static const _securePairKey = 'firebase_install_pair';
  static Future<(String, String)>? _pairFuture;

  /// Returns a matching installation id and secret. Android backup restores
  /// Hive before secure storage; when that leaves an id without its secret,
  /// rotate both values before any registration request can observe them.
  static Future<(String id, String secret)> getOrCreatePair({
    Box<dynamic>? settings,
    Future<String?> Function(String key)? secureRead,
    Future<void> Function(String key, String value)? secureWrite,
  }) {
    final pending = _pairFuture;
    if (pending != null) return pending;
    final future = _createPair(
      settings: settings,
      secureRead: secureRead,
      secureWrite: secureWrite,
    );
    _pairFuture = future;
    return future.whenComplete(() => _pairFuture = null);
  }

  static Future<(String id, String secret)> _createPair({
    Box<dynamic>? settings,
    Future<String?> Function(String key)? secureRead,
    Future<void> Function(String key, String value)? secureWrite,
  }) async {
    final box = settings ?? HiveStore.settings;
    const storage = FlutterSecureStorage();
    final read = secureRead ?? (String key) => storage.read(key: key);
    final write =
        secureWrite ??
        (String key, String value) => storage.write(key: key, value: value);
    final existingRaw = box.get(_key);
    final existingId = existingRaw is String ? existingRaw : null;
    final storedPair = await read(_securePairKey);
    if (storedPair != null) {
      try {
        final decoded = jsonDecode(storedPair);
        if (decoded is Map &&
            decoded['id'] is String &&
            decoded['secret'] is String &&
            (decoded['id'] as String).isNotEmpty &&
            (decoded['secret'] as String).isNotEmpty) {
          final id = decoded['id'] as String;
          final secret = decoded['secret'] as String;
          if (existingId != id) await box.put(_key, id);
          return (id, secret);
        }
      } on FormatException {
        // Fall through to legacy migration and pair creation.
      }
    }
    final secure = await read(_secureSecretKey);
    if (secure != null &&
        secure.isNotEmpty &&
        existingId != null &&
        existingId.isNotEmpty) {
      await write(
        _securePairKey,
        jsonEncode({'id': existingId, 'secret': secure}),
      );
      if (box.containsKey(_secretKey)) await box.delete(_secretKey);
      return (existingId, secure);
    }

    final legacyRaw = box.get(_secretKey);
    final legacy = legacyRaw is String ? legacyRaw : null;
    if ((secure == null || secure.isEmpty) &&
        legacy != null &&
        legacy.isNotEmpty &&
        existingId != null &&
        existingId.isNotEmpty) {
      await write(
        _securePairKey,
        jsonEncode({'id': existingId, 'secret': legacy}),
      );
      await write(_secureSecretKey, legacy);
      await box.delete(_secretKey);
      return (existingId, legacy);
    }

    final id = const Uuid().v4();
    final secret = base64UrlEncode(
      List<int>.generate(32, (_) => Random.secure().nextInt(256)),
    ).replaceAll('=', '');
    final pair = jsonEncode({'id': id, 'secret': secret});
    await write(_securePairKey, pair);
    await write(_secureSecretKey, secret);
    await box.put(_key, id);
    if (box.containsKey(_secretKey)) await box.delete(_secretKey);
    return (id, secret);
  }

  static Future<String> getOrCreate({Box<dynamic>? settings}) async =>
      (await getOrCreatePair(settings: settings)).$1;

  static Future<String> getOrCreateSecret({
    Box<dynamic>? settings,
    Future<String?> Function(String key)? secureRead,
    Future<void> Function(String key, String value)? secureWrite,
  }) async {
    final pair = await getOrCreatePair(
      settings: settings,
      secureRead: secureRead,
      secureWrite: secureWrite,
    );
    return pair.$2;
  }
}
