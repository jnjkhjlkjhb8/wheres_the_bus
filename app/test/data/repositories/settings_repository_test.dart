import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/repositories/settings_repository.dart';

import '../../support/helpers/in_memory_settings_store.dart';

void main() {
  SettingsRepository build([Map<String, Object?>? initial]) =>
      SettingsRepository(store: InMemorySettingsStore(initial));

  test('bool settings default to their documented values', () {
    final repo = build();
    expect(repo.liveActivityEnabled, isTrue);
    expect(repo.pushEnabled, isTrue);
  });

  test('bool settings round-trip through the store', () {
    final repo = build()..liveActivityEnabled = false;
    expect(repo.liveActivityEnabled, isFalse);
  });

  test('favMetroStations round-trips a list', () {
    final repo = build();
    expect(repo.favMetroStations, isEmpty);
    repo.favMetroStations = ['BL01', 'R02'];
    expect(repo.favMetroStations, ['BL01', 'R02']);
  });

  test('read alerts round-trip and start empty', () async {
    final repo = build();
    expect(repo.readAlerts(), isEmpty);
    await repo.setReadAlerts({'a', 'b'});
    expect(repo.readAlerts(), {'a', 'b'});
  });
}
