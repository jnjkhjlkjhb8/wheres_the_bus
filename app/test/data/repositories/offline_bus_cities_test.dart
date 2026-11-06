import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:wheres_the_bus/core/powersync/local_db.dart';
import 'package:wheres_the_bus/data/models/city_names.dart';
import 'package:wheres_the_bus/data/repositories/offline_bus_cities.dart';

class _MemoryDb implements LocalDb {
  _MemoryDb() {
    db
      ..execute(
        'CREATE TABLE search_vector (type TEXT, uid TEXT, city TEXT, '
        'lat REAL, lon REAL)',
      )
      ..execute('''
        INSERT INTO search_vector VALUES
        ('bus_station', 'S1', '台北市', 25.04, 121.51),
        ('bus_station', 'S2', '基隆市', 25.13, 121.74),
        ('bus_station', 'S3', '高雄市', NULL, NULL),
        ('bus_station', 'S4', '屏東縣', 22.6, 121.735),
        ('bus_station', 'S5', '雲林縣', 25.121, 120.3),
        ('bus_route', 'TAO1', '桃園市', NULL, NULL),
        ('bus_route', 'MIA1', '苗栗縣', NULL, NULL),
        ('bus_route', 'X1', '不明市', NULL, NULL)''');
  }

  final Database db = sqlite3.openInMemory();

  @override
  Future<List<Map<String, dynamic>>> getAll(
    String sql, [
    List<Object?> parameters = const [],
  ]) async => [
    for (final row in db.select(sql, parameters)) Map.of(row),
  ];
}

class _BrokenDb implements LocalDb {
  @override
  Future<List<Map<String, dynamic>>> getAll(
    String sql, [
    List<Object?> parameters = const [],
  ]) async => throw StateError('no such table: search_vector');
}

void main() {
  late _MemoryDb local;
  setUp(() => local = _MemoryDb());
  tearDown(() => local.db.close());

  test('adds the nearest stop city and favourite route cities', () async {
    final cities = await inferOfflineBusCities(
      db: local,
      chosen: const ['Tainan'],
      position: const [25.12, 121.73],
      favoriteRouteUids: const ['TAO1', 'MIA1', 'X1', 'gone'],
    );
    // S4 is nearer by longitude alone and S5 by latitude alone; only the
    // combined distance picks 基隆市. 苗栗縣 maps to the County spelling
    // bus_static uses; 不明市 maps to none.
    expect(cities, ['Keelung', 'MiaoliCounty', 'Tainan', 'Taoyuan']);
  });

  test('with no position or favourites the choice stands alone', () async {
    expect(
      await inferOfflineBusCities(
        db: local,
        chosen: const ['Taipei'],
        position: null,
        favoriteRouteUids: const [],
      ),
      ['Taipei'],
    );
  });

  test('an unsynced local table infers nothing', () async {
    expect(
      await inferOfflineBusCities(
        db: _BrokenDb(),
        chosen: const [],
        position: const [25, 121],
        favoriteRouteUids: const ['TAO1'],
      ),
      isEmpty,
    );
  });

  test('cityCodeOf prefers the County spelling and maps 公路客運', () {
    expect(cityCodeOf('苗栗縣'), 'MiaoliCounty');
    expect(cityCodeOf('公路客運'), 'InterCity');
    expect(cityCodeOf('台北市'), 'Taipei');
    expect(cityCodeOf('火星'), isNull);
  });
}
