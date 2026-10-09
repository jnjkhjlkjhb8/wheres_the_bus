import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:wheres_the_bus/core/storage/hive_store.dart';

void main() {
  setUpAll(() async {
    Hive.init('./.dart_tool/hive_test_recents');
    await Hive.openBox<dynamic>('recent_searches');
  });

  test('addRecentSearch dedupes and caps at 10, newest first', () async {
    for (var i = 0; i < 12; i++) {
      await HiveStore.addRecentSearch(
        {'type': 'busRoute', 'uid': '$i', 'name': '$i'},
      );
    }
    await HiveStore.addRecentSearch(
      {'type': 'busRoute', 'uid': '11', 'name': '11'},
    );
    final r = HiveStore.recentSearches;
    expect(r.length, 10);
    expect(r.first['uid'], '11');
    expect(r.where((e) => e['uid'] == '11').length, 1);
  });
}
