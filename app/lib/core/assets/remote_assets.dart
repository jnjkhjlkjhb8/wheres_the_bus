import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:wheres_the_bus/core/http/http_client.dart';

typedef RemoteAsset = ({File file, String hash});

/// Files the router serves under /api/assets instead of the app bundling them,
/// mirrored into app support storage. `manifest.json` maps each relative path
/// to a content hash; a file is fetched again only when its hash changes.
class RemoteAssets {
  RemoteAssets({required Future<Directory> Function() root, required Dio dio})
    : _root = root,
      _dio = dio;

  static final RemoteAssets instance = RemoteAssets(
    root: () async => Directory(
      p.join((await getApplicationSupportDirectory()).path, 'remote_assets'),
    ),
    dio: HttpClient.instance.dio,
  );

  static const _endpoint = '/api/assets';
  static const _manifest = 'manifest.json';

  final Future<Directory> Function() _root;
  final Dio _dio;
  final ValueNotifier<int> _revision = ValueNotifier(0);
  Directory? _dir;
  Map<String, String> _have = const {};

  /// Bumps whenever the set of files on disk changes.
  ValueListenable<int> get revision => _revision;

  RemoteAsset? lookup(String path) {
    final dir = _dir;
    final hash = _have[path];
    if (dir == null || hash == null) return null;
    return (file: File(p.join(dir.path, path)), hash: hash);
  }

  /// Reads what earlier syncs left on disk, without touching the network.
  Future<void> load() async {
    final dir = _dir ??= await _root();
    final local = File(p.join(dir.path, _manifest));
    if (!local.existsSync()) return;
    _publish(parseManifest(await local.readAsString()));
  }

  /// [sync] for startup, where offline or a router without the volume simply
  /// leaves the last mirror in place.
  Future<void> refresh() => sync().catchError((Object _) {});

  /// Throws on any network or disk failure; whatever was already on disk
  /// stays usable.
  Future<void> sync() async {
    await load();
    final dir = _dir!;
    final response = await _dio.get<String>(
      '$_endpoint/$_manifest',
      options: Options(responseType: ResponseType.plain),
    );
    final remote = parseManifest(response.data ?? '');
    for (final stale in _have.keys.where((k) => !remote.containsKey(k))) {
      await _delete(File(p.join(dir.path, stale)));
    }
    for (final MapEntry(key: path, value: hash) in remote.entries) {
      if (_have[path] != hash) await _download(dir, path);
    }
    await File(p.join(dir.path, _manifest)).writeAsString(jsonEncode(remote));
    _publish(remote);
  }

  Future<void> _download(Directory dir, String path) async {
    final target = File(p.join(dir.path, path));
    final partial = '${target.path}.part';
    await target.parent.create(recursive: true);
    await _dio.download('$_endpoint/$path', partial);
    await File(partial).rename(target.path);
    // FileImage caches by path, so a file replaced under the same name would
    // keep showing its old pixels until the app restarts.
    PaintingBinding.instance.imageCache.evict(FileImage(target));
  }

  static Future<void> _delete(File file) async {
    if (file.existsSync()) await file.delete();
  }

  void _publish(Map<String, String> have) {
    _have = have;
    _revision.value++;
  }

  @visibleForTesting
  void debugSeed(Directory dir, Map<String, String> have) {
    _dir = dir;
    _publish(have);
  }

  /// Keeps only string-hashed entries whose path stays inside the mirror: the
  /// manifest names files we write to disk, so `../` or an absolute path must
  /// never reach [File].
  @visibleForTesting
  static Map<String, String> parseManifest(String body) {
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      return const {};
    }
    if (decoded is! Map<String, dynamic>) return const {};
    return {
      for (final MapEntry(:key, :value) in decoded.entries)
        if (value is String && _isSafePath(key)) key: value,
    };
  }

  static bool _isSafePath(String path) =>
      path != _manifest && !path.contains(r'\') && _staysInside(path);

  static bool _staysInside(String path) {
    final parts = p.split(path);
    return !p.isAbsolute(path) &&
        parts.isNotEmpty &&
        parts.every((part) => part != '..' && part != '.');
  }
}
