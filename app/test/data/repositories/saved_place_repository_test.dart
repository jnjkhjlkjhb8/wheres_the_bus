import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:wheres_the_bus/data/repositories/saved_place_repository.dart';
import 'package:wheres_the_bus/features/go/model/planned_place.dart';
import 'package:wheres_the_bus/features/go/model/saved_place_icons.dart';

PlannedPlace _place(String name, double lat, double lon, {String? icon}) =>
    PlannedPlace(name: name, latLng: LatLng(lat, lon), iconKey: icon);

void main() {
  const repo = SavedPlaceRepository.instance;

  setUpAll(() async {
    Hive.init('./.dart_tool/hive_test_saved_places');
    await Hive.openBox<dynamic>('settings');
  });

  setUp(() => Hive.box<dynamic>('settings').clear());

  test('add preserves insertion order and stores label + icon', () async {
    await repo.add(_place('住家', 25.1, 121.5, icon: 'home'));
    await repo.add(_place('公司', 25.2, 121.6, icon: 'work'));

    final all = repo.all();
    expect(all.map((p) => p.name).toList(), ['住家', '公司']);
    expect(all.first.iconKey, 'home');
    expect(all.last.latLng, const LatLng(25.2, 121.6));
  });

  test('re-adding the same coords edits in place, not duplicates', () async {
    await repo.add(_place('住家', 25.123456, 121.5, icon: 'home'));
    await repo.add(_place('公司', 25.2, 121.6, icon: 'work'));
    // Same coords (differ only past the 6th decimal) with a new label/icon is
    // an edit, not a second pin.
    await repo.add(_place('阿嬤家', 25.1234561, 121.5, icon: 'star'));

    final all = repo.all();
    expect(all.length, 2);
    expect(all.map((p) => p.name), contains('阿嬤家'));
    expect(all.map((p) => p.name), isNot(contains('住家')));
    expect(all.firstWhere((p) => p.name == '阿嬤家').iconKey, 'star');
  });

  test('contains matches by coordinates regardless of label', () async {
    await repo.add(_place('住家', 25.1, 121.5, icon: 'home'));

    expect(repo.contains(_place('別的名字', 25.1, 121.5)), isTrue);
    expect(repo.contains(_place('住家', 30, 130)), isFalse);
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

  test('remove deletes by coordinates even after a label edit', () async {
    await repo.add(_place('住家', 25.1, 121.5, icon: 'home'));

    await repo.remove(_place('任何名稱', 25.1, 121.5));

    expect(repo.all(), isEmpty);
  });

  test('icon resolve falls back for an unknown key', () {
    expect(SavedPlaceIcons.resolve('home'), Icons.home_rounded);
    expect(
      SavedPlaceIcons.resolve('an-icon-that-was-removed'),
      SavedPlaceIcons.resolve(SavedPlaceIcons.fallback),
    );
  });
}
