import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:wheres_the_bus/data/repositories/reminders_repository.dart';

// Exercises the Hive-backed store behind RemindersRepository.instance, which
// the in-memory store injected by the other reminder tests never reaches.
void main() {
  final repo = RemindersRepository();
  final future = DateTime.now().add(const Duration(hours: 1));

  setUpAll(() async {
    Hive.init('./.dart_tool/hive_test_reminders');
    await Hive.openBox<dynamic>('arrival_reminders');
  });

  setUp(() async {
    await Hive.box<dynamic>('arrival_reminders').clear();
  });

  test('a stored reminder is active until it expires', () async {
    await repo.put('R1', 'S1', 'rem-1', future);
    expect(repo.active('R1'), {'S1': 'rem-1'});
  });

  test('an expired reminder is filtered out on read', () async {
    await repo.put(
      'R1',
      'S1',
      'rem-1',
      DateTime.now().subtract(const Duration(seconds: 1)),
    );
    expect(repo.active('R1'), isEmpty);
  });

  test('removing one stop keeps the other stops on the route', () async {
    await repo.put('R1', 'S1', 'rem-1', future);
    await repo.put('R1', 'S2', 'rem-2', future);
    await repo.remove(routeUid: 'R1', stopUid: 'S1');
    expect(repo.active('R1'), {'S2': 'rem-2'});
  });

  test('removing the last stop deletes the route entry', () async {
    await repo.put('R1', 'S1', 'rem-1', future);
    await repo.remove(routeUid: 'R1', stopUid: 'S1');
    expect(repo.active('R1'), isEmpty);
    expect(Hive.box<dynamic>('arrival_reminders').containsKey('R1'), isFalse);
  });

  test('reminders on another route are untouched by remove', () async {
    await repo.put('R1', 'S1', 'rem-1', future);
    await repo.put('R2', 'S9', 'rem-9', future);
    await repo.remove(routeUid: 'R1', stopUid: 'S1');
    expect(repo.active('R2'), {'S9': 'rem-9'});
  });
}
