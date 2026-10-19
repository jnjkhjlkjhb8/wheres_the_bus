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
    return _restoreOrCreatePair(box, read, write);
  }

  static Future<(String, String)> _restoreOrCreatePair(
    Box<dynamic> box,
    Future<String?> Function(String key) read,
    Future<void> Function(String key, String value) write,
  ) async {
    final storedPair = _decodePair(await read(_securePairKey));
    if (storedPair != null) {
      if (box.get(_key) != storedPair.$1) await box.put(_key, storedPair.$1);
      return storedPair;
    }
    final secure = _nonemptyString(await read(_secureSecretKey));
    final legacyPair = _legacyPair(box, secure);
    if (legacyPair != null) {
      await _persistPair(box, legacyPair, write, persistSecret: secure == null);
      return legacyPair;
    }
    return _newPair(box, write);
  }

  static (String, String)? _legacyPair(Box<dynamic> box, String? secure) {
    final id = _nonemptyString(box.get(_key));
    if (id == null) return null;
    final secret = secure ?? _nonemptyString(box.get(_secretKey));
    return secret == null ? null : (id, secret);
  }

  static Future<(String, String)> _newPair(
    Box<dynamic> box,
    Future<void> Function(String key, String value) write,
  ) async {
    final id = const Uuid().v4();
    final secret = base64UrlEncode(
      List<int>.generate(32, (_) => Random.secure().nextInt(256)),
    ).replaceAll('=', '');
    final pair = (id, secret);
    await _persistPair(box, pair, write, persistSecret: true);
    return pair;
  }

  static String? _nonemptyString(Object? value) =>
      value is String && value.isNotEmpty ? value : null;

  static (String, String)? _decodePair(String? stored) {
    if (stored == null) return null;
    try {
      return _decodedPair(jsonDecode(stored));
    } on FormatException {
      return null;
    }
  }

  static (String, String)? _decodedPair(Object? decoded) {
    if (decoded is! Map) return null;
    final id = _nonemptyString(decoded['id']);
    final secret = _nonemptyString(decoded['secret']);
    if (id == null || secret == null) return null;
    return (id, secret);
  }

  static Future<void> _persistPair(
    Box<dynamic> box,
    (String, String) pair,
    Future<void> Function(String key, String value) write, {
    required bool persistSecret,
  }) async {
    final (id, secret) = pair;
    await write(_securePairKey, jsonEncode({'id': id, 'secret': secret}));
    if (persistSecret) await write(_secureSecretKey, secret);
    if (box.get(_key) != id) await box.put(_key, id);
    if (box.containsKey(_secretKey)) await box.delete(_secretKey);
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
