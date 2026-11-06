import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:wheres_the_bus/core/errors/app_error.dart';
import 'package:wheres_the_bus/core/powersync/local_db.dart';
import 'package:wheres_the_bus/data/models/search_models.dart';
import 'package:wheres_the_bus/data/repositories/search_repository.dart';

/// Runs the repository's real SQL against an in-memory copy of the
/// PowerSync `search_vector` table.
class _MemoryDb implements LocalDb {
  _MemoryDb() {
    db.execute('''
      CREATE TABLE search_vector (
        type TEXT, uid TEXT, name TEXT, alias TEXT, city TEXT,
        depart TEXT, destin TEXT, lat REAL, lon REAL)''');
  }

  final Database db = sqlite3.openInMemory();

  void add(
    String type,
    String uid,
    String name, {
    String? alias,
    String city = 'Taipei',
    String? depart,
    String? destin,
  }) => db.execute('INSERT INTO search_vector VALUES (?,?,?,?,?,?,?,?,?)', [
    type,
    uid,
    name,
    alias,
    city,
    depart,
    destin,
    25.04,
    121.5,
  ]);

  @override
  Future<List<Map<String, dynamic>>> getAll(
    String sql, [
    List<Object?> parameters = const [],
  ]) async => [
    for (final row in db.select(sql, parameters))
      Map<String, dynamic>.from(row),
  ];
}

class _MissingTableDb implements LocalDb {
  @override
  Future<List<Map<String, dynamic>>> getAll(
    String sql, [
    List<Object?> parameters = const [],
  ]) async => throw StateError('no such table: search_vector');
}

SearchRepository _offlineRepo(LocalDb db) => SearchRepository(
  localDb: db,
  httpFetch: (query, limit, city) async =>
      throw const SocketException('no route to host'),
);

void main() {
  late _MemoryDb local;

  setUp(() {
    local = _MemoryDb()
      ..add('bus_route', 'TPE307', '307', depart: '撫遠街', destin: '板橋前站')
      ..add('bus_route', 'TPE30', '30', depart: '民生社區', destin: '307站')
      ..add('bus_station', 'S1', '台北車站', alias: 'tbcz,ㄊㄞㄅㄟ')
      ..add('bus_station', 'S2', '北門', city: 'NewTaipei')
      ..add('tra_station', 'T1', '臺北')
      ..add('bus_station', 'S3', '100%站');
  });
  tearDown(() => local.db.close());

  test(
    'offline: answers from the local copy, prefix ahead of contains',
    () async {
      final results = await _offlineRepo(local).search('307');
      expect(results.map((r) => r.uid), ['TPE307', 'TPE30']);
      expect(results.first.subtitle, '撫遠街 → 板橋前站');
      expect(results.first.lat, 25.04);
    },
  );

  test('offline: matches toned zhuyin against toneless aliases', () async {
    final results = await _offlineRepo(local).search('ㄊㄞˊㄅㄟˇ');
    expect(results.single.uid, 'S1');
  });

  test('offline: honours the city filter', () async {
    final results = await _offlineRepo(local).search('北', city: 'NewTaipei');
    expect(results.map((r) => r.uid), ['S2']);
  });

  test('offline: rail station rows have nowhere to navigate', () async {
    await expectLater(
      _offlineRepo(local).search('臺北'),
      throwsA(isA<OfflineError>()),
    );
  });

  test('offline: a % in the query is literal, not a wildcard', () async {
    final results = await _offlineRepo(local).search('0%');
    expect(results.map((r) => r.uid), ['S3']);
  });

  test('offline with no match keeps the offline error', () async {
    await expectLater(
      _offlineRepo(local).search('不存在'),
      throwsA(isA<OfflineError>()),
    );
  });

  test('offline before the table has synced keeps the offline error', () async {
    await expectLater(
      _offlineRepo(_MissingTableDb()).search('307'),
      throwsA(isA<OfflineError>()),
    );
  });

  test('a server-side failure is never answered locally', () async {
    final repo = SearchRepository(
      localDb: local,
      httpFetch: (query, limit, city) async => throw StateError('500'),
    );
    await expectLater(repo.search('307'), throwsA(isA<UnknownError>()));
  });

  test('offline answers are not memoized', () async {
    var online = false;
    final repo = SearchRepository(
      localDb: local,
      httpFetch: (query, limit, city) async {
        if (!online) throw const SocketException('down');
        return const [
          SearchResult(
            type: SearchResultType.busRoute,
            uid: 'REMOTE',
            name: '307',
            subtitle: '',
          ),
        ];
      },
    );
    await repo.search('307');
    online = true;
    expect((await repo.search('307')).single.uid, 'REMOTE');
  });

  test('stripZhuyinTones leaves non-zhuyin input alone', () {
    expect(stripZhuyinTones('ㄅㄟˇ'), 'ㄅㄟ');
    expect(stripZhuyinTones('307'), '307');
  });
}
