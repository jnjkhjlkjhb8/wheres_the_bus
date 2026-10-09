import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/repositories/reminders_repository.dart';

import '../../support/helpers/in_memory_reminders_store.dart';

void main() {
  RemindersRepository build() =>
      RemindersRepository(store: InMemoryRemindersStore());

  test('put then active round-trips, scoped per route', () async {
    final repo = build();
    final soon = DateTime.now().add(const Duration(hours: 1));
    await repo.put('R1', 'S1', 'srv-1', soon);
    await repo.put('R1', 'S2', 'srv-2', soon);
    await repo.put('R2', 'S9', 'srv-9', soon);

    expect(repo.active('R1'), {'S1': 'srv-1', 'S2': 'srv-2'});
    expect(repo.active('R2'), {'S9': 'srv-9'});
    expect(repo.active('unknown'), isEmpty);
  });

  test('expired reminders are filtered on read', () async {
    final repo = build();
    await repo.put(
      'R1',
      'S1',
      'live',
      DateTime.now().add(const Duration(hours: 1)),
    );
    await repo.put(
      'R1',
      'S2',
      'stale',
      DateTime.now().subtract(const Duration(minutes: 1)),
    );
    expect(repo.active('R1'), {'S1': 'live'});
  });

  test('remove deletes one stop and clears the route when empty', () async {
    final repo = build();
    final soon = DateTime.now().add(const Duration(hours: 1));
    await repo.put('R1', 'S1', 'srv-1', soon);
    await repo.put('R1', 'S2', 'srv-2', soon);

    await repo.remove('R1', 'S1');
    expect(repo.active('R1'), {'S2': 'srv-2'});

    await repo.remove('R1', 'S2');
    expect(repo.active('R1'), isEmpty);
  });
}
