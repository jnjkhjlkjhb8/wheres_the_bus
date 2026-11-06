import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:wheres_the_bus/core/powersync/local_db.dart';
import 'package:wheres_the_bus/data/generated/bus.pbgrpc.dart';
import 'package:wheres_the_bus/data/repositories/bus_repository.dart';

import '../../support/helpers/fake_grpc.dart';

class _FailingRouteClient implements Bus_Route_ServiceClient {
  _FailingRouteClient(this.error);

  final GrpcError error;

  @override
  ResponseFuture<Resp_Bus_static> static(
    Bus_Ask_Route request, {
    CallOptions? options,
  }) => FakeResponseFuture(Future.error(error));

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} not faked');
}

class _Rows implements LocalDb {
  _Rows(this.rows);

  final List<Map<String, dynamic>> rows;
  final seen = <List<Object?>>[];

  @override
  Future<List<Map<String, dynamic>>> getAll(
    String sql, [
    List<Object?> parameters = const [],
  ]) async {
    seen.add(parameters);
    return rows;
  }
}

Map<String, dynamic> _row({String stopsGo = '[["S1","撫遠街",1,25.05,121]]'}) => {
  'id': 'TPE307',
  'city': 'Taipei',
  'route_name': '307',
  'sub_route_name': '307莒光',
  'depart': '撫遠街',
  'destin': '板橋',
  'headsign_go': '板橋',
  'headsign_return': '撫遠街',
  'stops_go': stopsGo,
  'stops_return': '[]',
};

/// The PowerSync table view as SQLite sees it: `id` plus the declared columns.
class _Sqlite implements LocalDb {
  _Sqlite(Map<String, dynamic> row) {
    final cols = row.keys.join(', ');
    final marks = List.filled(row.length, '?').join(', ');
    db
      ..execute('CREATE TABLE bus_route_offline ($cols)')
      ..execute('INSERT INTO bus_route_offline VALUES ($marks)', [
        ...row.values,
      ]);
  }

  final Database db = sqlite3.openInMemory();

  @override
  Future<List<Map<String, dynamic>>> getAll(
    String sql, [
    List<Object?> parameters = const [],
  ]) async => [for (final r in db.select(sql, parameters)) Map.of(r)];
}

BusRepository _repo(GrpcError error, LocalDb db) =>
    BusRepository(routeClient: _FailingRouteClient(error), localDb: db);

void main() {
  test('offline with no cache serves the slim local route', () async {
    final db = _Rows([_row()]);
    final route = await _repo(const GrpcError.unavailable(), db).routeStatic(
      'TPE307',
    );
    expect(db.seen.single, ['TPE307']);
    expect(route.routeName, '307');
    expect(route.subRouteName, '307莒光');
    expect(route.headsignGo, '板橋');
    expect(route.stopsGo.single.stopName, '撫遠街');
    expect(route.stopsGo.single.lon, 121.0);
    expect(route.stopsReturn, isEmpty);
    expect(route.geometryGo, isEmpty);
    expect(route.fare, isNull);
  });

  test('the fallback query runs against the real table shape', () async {
    final db = _Sqlite(_row());
    addTearDown(db.db.close);
    final route = await _repo(const GrpcError.unavailable(), db).routeStatic(
      'TPE307',
    );
    expect(route.stopsGo.single.stopUid, 'S1');
  });

  test('a timeout falls back too', () async {
    final route = await _repo(
      const GrpcError.deadlineExceeded(),
      _Rows([_row()]),
    ).routeStatic('TPE307');
    expect(route.subRouteUid, 'TPE307');
  });

  test('a definitive server answer is never replaced locally', () async {
    final db = _Rows([_row()]);
    await expectLater(
      _repo(const GrpcError.notFound(), db).routeStatic('TPE307'),
      throwsA(isA<GrpcError>()),
    );
    expect(db.seen, isEmpty);
  });

  test('a route outside the synced cities keeps the offline error', () async {
    await expectLater(
      _repo(const GrpcError.unavailable(), _Rows([])).routeStatic('TPE307'),
      throwsA(
        isA<GrpcError>().having((e) => e.code, 'code', StatusCode.unavailable),
      ),
    );
  });

  test('a malformed stop list is a miss, not a crash', () async {
    await expectLater(
      _repo(
        const GrpcError.unavailable(),
        _Rows([_row(stopsGo: '[["S1","x","not a number",0,0]]')]),
      ).routeStatic('TPE307'),
      throwsA(isA<GrpcError>()),
    );
  });
}
