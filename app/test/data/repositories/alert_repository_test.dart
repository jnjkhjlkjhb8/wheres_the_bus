import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/repositories/alert_repository.dart';
import 'package:wheres_the_bus/data/repositories/settings_repository.dart';

import '../../support/helpers/in_memory_settings_store.dart';

void main() {
  test('read-state starts empty and round-trips through settings', () async {
    final repo = AlertRepository(
      settings: SettingsRepository(store: InMemorySettingsStore()),
    );
    expect(repo.readAlerts(), isEmpty);

    await repo.persistReadAlerts({'msg-1', 'msg-2'});
    expect(repo.readAlerts(), {'msg-1', 'msg-2'});
  });
}
