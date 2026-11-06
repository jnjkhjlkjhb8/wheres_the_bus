import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:wheres_the_bus/core/lifecycle/app_network.dart';
import 'package:wheres_the_bus/data/models/favorite.dart';
import 'package:wheres_the_bus/data/repositories/bus_repository.dart';
import 'package:wheres_the_bus/data/repositories/offline_prefetch.dart';
import 'package:wheres_the_bus/data/repositories/thsr_repository.dart';
import 'package:wheres_the_bus/data/repositories/tra_repository.dart';

final _calls = <String>[];

class _Bus implements BusRepository {
  @override
  dynamic noSuchMethod(Invocation i) {
    final name = i.memberName.toString().split('"')[1];
    _calls.add('bus.$name:${i.positionalArguments.join(',')}');
    if (name == 'routeDaily') throw StateError('server down');
    if (i.positionalArguments.first == 'DROP') AppNetwork.online.value = false;
    return Future<Never>.error(StateError('not needed'));
  }
}

class _Tra implements TraRepository {
  @override
  dynamic noSuchMethod(Invocation i) {
    final name = i.memberName.toString().split('"')[1];
    _calls.add('tra.$name:${i.positionalArguments.join(',')}');
    return Future<Never>.error(StateError('not needed'));
  }
}

class _Thsr implements ThsrRepository {
  @override
  dynamic noSuchMethod(Invocation i) {
    final name = i.memberName.toString().split('"')[1];
    _calls.add('thsr.$name:${i.positionalArguments.join(',')}');
    return Future<Never>.error(StateError('not needed'));
  }
}

Future<void> _run({
  List<Favorite> favorites = const [],
  List<Map<String, dynamic>> recentOd = const [],
}) => warmOfflineStatics(
  bus: _Bus(),
  tra: _Tra(),
  thsr: _Thsr(),
  favorites: favorites,
  recentOd: recentOd,
  now: DateTime(2026, 11, 6),
);

void main() {
  setUp(() async {
    _calls.clear();
    Hive.init('./.dart_tool/hive_test_offline_prefetch');
    await Hive.openBox<dynamic>('static_cache');
  });
  tearDown(() async => Hive.box<dynamic>('static_cache').close());

  test('warms bus favourites and keeps going past a failed read', () async {
    await _run(
      favorites: const [
        Favorite(type: FavoriteType.busRoute, refId: 'TPE1', title: '307'),
        Favorite(type: FavoriteType.busStop, refId: 'G1', title: '台北車站'),
        // Legacy name-as-refId stop: nothing to fetch.
        Favorite(type: FavoriteType.busStop, refId: '市府', title: '市府'),
        Favorite(type: FavoriteType.metroStation, refId: 'BL12', title: 'x'),
      ],
    );
    expect(_calls, [
      'bus.routeStatic:TPE1',
      'bus.routeDaily:TPE1',
      'bus.stationGroup:G1',
    ]);
  });

  test("warms today's rail OD pairs, falling back to station names", () async {
    await _run(
      recentOd: const [
        {
          'system': 'tra',
          'originId': '1000',
          'originName': '臺北',
          'destId': '',
          'destName': '新竹',
        },
        {
          'system': 'thsr',
          'originId': '0990',
          'originName': '南港',
          'destId': '1070',
          'destName': '左營',
        },
        {'system': 'tra', 'originName': '', 'destName': '新竹'},
        {'system': 'mrt', 'originName': 'A', 'destName': 'B'},
      ],
    );
    expect(_calls, [
      'tra.timetable:2026-11-06,1000,新竹',
      'tra.fares:1000,新竹',
      'thsr.timetable:2026-11-06,0990,1070',
      'thsr.fares:2026-11-06,0990,1070',
    ]);
  });

  test('does nothing offline', () async {
    AppNetwork.online.value = false;
    addTearDown(AppNetwork.reset);
    await _run(
      favorites: const [
        Favorite(type: FavoriteType.busRoute, refId: 'TPE1', title: '307'),
      ],
    );
    expect(_calls, isEmpty);
  });

  test('stops as soon as the device goes offline mid-run', () async {
    addTearDown(AppNetwork.reset);
    await _run(
      favorites: const [
        Favorite(type: FavoriteType.busRoute, refId: 'DROP', title: 'x'),
      ],
    );
    expect(_calls, ['bus.routeStatic:DROP']);
  });

  test('does nothing before the cache box is open', () async {
    await Hive.box<dynamic>('static_cache').close();
    await _run(
      favorites: const [
        Favorite(type: FavoriteType.busRoute, refId: 'TPE1', title: '307'),
      ],
    );
    expect(_calls, isEmpty);
    await Hive.openBox<dynamic>('static_cache');
  });
}
