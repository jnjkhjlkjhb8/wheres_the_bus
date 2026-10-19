import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/core/assets/remote_assets.dart';

class _Router implements HttpClientAdapter {
  Map<String, String> files = {};
  Map<String, String> manifest = {};
  int status = 200;
  final requests = <String>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options.path);
    const prefix = '/api/assets/';
    final name = options.path.substring(prefix.length);
    final body = name == 'manifest.json' ? jsonEncode(manifest) : files[name];
    if (status != 200 || body == null) {
      return ResponseBody.fromString('', status == 200 ? 404 : status);
    }
    return ResponseBody.fromString(body, 200);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late _Router router;
  late RemoteAssets assets;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('remote_assets');
    router = _Router();
    assets = RemoteAssets(
      root: () async => dir,
      dio: Dio(BaseOptions(baseUrl: 'http://router'))
        ..httpClientAdapter = router,
    );
  });
  tearDown(() => dir.deleteSync(recursive: true));

  group('parseManifest', () {
    test('keeps string hashes under relative paths', () {
      expect(
        RemoteAssets.parseManifest('{"mrt/a.svg":"h1","b.png":"h2"}'),
        {'mrt/a.svg': 'h1', 'b.png': 'h2'},
      );
    });

    test('drops names that could leave the mirror or shadow the manifest', () {
      const hostile = [
        '../x',
        'a/../../x',
        'a/./b',
        '/etc/passwd',
        r'a\b',
        '',
        'manifest.json',
      ];
      final body = jsonEncode({for (final p in hostile) p: 'h', 'ok': 'h'});
      expect(RemoteAssets.parseManifest(body), {'ok': 'h'});
    });

    test('drops non-string hashes and tolerates garbage', () {
      expect(RemoteAssets.parseManifest('{"a":1,"b":null,"c":"h"}'), {
        'c': 'h',
      });
      expect(RemoteAssets.parseManifest('not json'), isEmpty);
      expect(RemoteAssets.parseManifest('[1,2]'), isEmpty);
    });
  });

  test('lookup knows nothing before a load or sync', () {
    expect(assets.lookup('a.svg'), isNull);
  });

  test('sync downloads, publishes and survives a restart', () async {
    router
      ..manifest = {'mrt/a.svg': 'h1'}
      ..files = {'mrt/a.svg': '<svg/>'};
    var bumps = 0;
    assets.revision.addListener(() => bumps++);

    await assets.sync();

    final found = assets.lookup('mrt/a.svg')!;
    expect(found.hash, 'h1');
    expect(found.file.readAsStringSync(), '<svg/>');
    expect(bumps, greaterThan(0));
    expect(
      Directory(dir.path)
          .listSync(recursive: true)
          .whereType<File>()
          .any(
            (f) => f.path.endsWith('.part'),
          ),
      isFalse,
    );

    final restarted = RemoteAssets(root: () async => dir, dio: Dio());
    await restarted.load();
    expect(restarted.lookup('mrt/a.svg')!.hash, 'h1');
  });

  test('sync fetches only what changed and deletes what vanished', () async {
    router
      ..manifest = {'a.svg': 'h1', 'b.svg': 'h1'}
      ..files = {'a.svg': 'A1', 'b.svg': 'B1'};
    await assets.sync();
    router.requests.clear();

    router
      ..manifest = {'a.svg': 'h2'}
      ..files = {'a.svg': 'A2', 'b.svg': 'B1'};
    await assets.sync();

    expect(router.requests, ['/api/assets/manifest.json', '/api/assets/a.svg']);
    expect(assets.lookup('a.svg')!.file.readAsStringSync(), 'A2');
    expect(assets.lookup('b.svg'), isNull);
    expect(File('${dir.path}/b.svg').existsSync(), isFalse);
  });

  test('a router that cannot answer leaves the mirror usable', () async {
    router
      ..manifest = {'a.svg': 'h1'}
      ..files = {'a.svg': 'A1'};
    await assets.sync();

    router.status = 503;
    await expectLater(assets.sync(), throwsA(isA<DioException>()));
    await assets.refresh();

    expect(assets.lookup('a.svg')!.file.readAsStringSync(), 'A1');
  });

  test('a file the router lists but cannot serve fails the sync', () async {
    router.manifest = {'gone.svg': 'h1'};
    await expectLater(assets.sync(), throwsA(isA<DioException>()));
    expect(assets.lookup('gone.svg'), isNull);
  });
}
