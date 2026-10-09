import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:wheres_the_bus/data/repositories/place_recent_repository.dart';
import 'package:wheres_the_bus/features/go/model/planned_place.dart';

PlannedPlace _place(String name, double lat, double lon) =>
    PlannedPlace(name: name, latLng: LatLng(lat, lon));

void main() {
  const repo = PlaceRecentRepository.instance;

  setUpAll(() async {
    Hive.init('./.dart_tool/hive_test_place_recents');
    await Hive.openBox<dynamic>('settings');
  });

  setUp(() => Hive.box<dynamic>('settings').clear());

  test('add prepends newest and returns stored coordinates', () async {
    await repo.add(_place('A', 25.1, 121.5));
    await repo.add(_place('B', 25.2, 121.6));

    final all = repo.all();
    expect(all.map((p) => p.name).toList(), ['B', 'A']);
    expect(all.first.latLng, const LatLng(25.2, 121.6));
  });

  test('re-adding same name+coords dedupes and moves to front', () async {
    await repo.add(_place('A', 25.123456, 121.5));
    await repo.add(_place('B', 25.2, 121.6));
    // Same name, coords differ only past the 6th decimal -> same place.
    await repo.add(_place('A', 25.1234561, 121.5));

    expect(repo.all().map((p) => p.name).toList(), ['A', 'B']);
  });

  test('caps at 8 items, dropping the oldest', () async {
    for (var i = 0; i < 10; i++) {
      await repo.add(_place('P$i', (25 + i).toDouble(), 121));
    }
    final names = repo.all().map((p) => p.name).toList();
    expect(names.length, 8);
    expect(names.first, 'P9');
    expect(names.contains('P0'), isFalse);
    expect(names.contains('P1'), isFalse);
  });

  test('never stores the current-location pseudo-place', () async {
    await repo.add(
      const PlannedPlace(
        name: '目前位置',
        latLng: LatLng(25, 121),
        isCurrentLocation: true,
      ),
    );
    expect(repo.all(), isEmpty);
  });

  test('remove deletes the matching place', () async {
    await repo.add(_place('A', 25.1, 121.5));
    await repo.add(_place('B', 25.2, 121.6));

    await repo.remove(_place('A', 25.1, 121.5));

    expect(repo.all().map((p) => p.name).toList(), ['B']);
  });
}
