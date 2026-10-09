import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:wheres_the_bus/core/storage/hive_store.dart';

void main() {
  setUpAll(() async {
    Hive.init('./.dart_tool/hive_test_reminders');
    await Hive.openBox<dynamic>('arrival_reminders');
  });

  setUp(() => Hive.box<dynamic>('arrival_reminders').clear());

  test('put then activeReminders round-trips, scoped per route', () async {
    final soon = DateTime.now().add(const Duration(hours: 1));
    await HiveStore.putReminder('R1', 'S1', 'srv-1', soon);
    await HiveStore.putReminder('R1', 'S2', 'srv-2', soon);
    await HiveStore.putReminder('R2', 'S9', 'srv-9', soon);

    expect(HiveStore.activeReminders('R1'), {'S1': 'srv-1', 'S2': 'srv-2'});
    expect(HiveStore.activeReminders('R2'), {'S9': 'srv-9'});
    expect(HiveStore.activeReminders('unknown'), isEmpty);
  });

  test('expired reminders are filtered out on read', () async {
    await HiveStore.putReminder(
      'R1',
      'S1',
      'live',
      DateTime.now().add(const Duration(hours: 1)),
    );
    await HiveStore.putReminder(
      'R1',
      'S2',
      'stale',
      DateTime.now().subtract(const Duration(minutes: 1)),
    );
    expect(HiveStore.activeReminders('R1'), {'S1': 'live'});
  });

  test('remove deletes one stop and clears the route when empty', () async {
    final soon = DateTime.now().add(const Duration(hours: 1));
    await HiveStore.putReminder('R1', 'S1', 'srv-1', soon);
    await HiveStore.putReminder('R1', 'S2', 'srv-2', soon);

    await HiveStore.removeReminder('R1', 'S1');
    expect(HiveStore.activeReminders('R1'), {'S2': 'srv-2'});

    await HiveStore.removeReminder('R1', 'S2');
    expect(HiveStore.activeReminders('R1'), isEmpty);
  });
}
