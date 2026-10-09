import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:wheres_the_bus/core/storage/hive_store.dart';
import 'package:wheres_the_bus/data/generated/maas.pb.dart' as maas;
import 'package:wheres_the_bus/data/models/plan_models.dart';
import 'package:wheres_the_bus/features/go/bloc/plan_bloc.dart';
import 'package:wheres_the_bus/features/go/bloc/plan_event.dart';

PlanRoute _route() => PlanRoute.fromProto(
  maas.Route(
    startTime: '2026-07-11T21:36:41',
    endTime: '2026-07-11T22:00:00',
    transfers: 1,
    sections: [
      maas.Section(
        type: 'transit',
        departure: maas.Place(name: '台北車站'),
        arrival: maas.Place(name: '市政府站'),
      ),
    ],
  ),
);

void main() {
  setUpAll(() async {
    final dir = Directory.systemTemp.createTempSync('hive_legacy_key');
    Hive.init(dir.path);
    await Hive.openBox<dynamic>('saved_plans');
  });

  setUp(() async {
    await HiveStore.savedPlans.clear();
  });

  test('un-save removes an entry stored under a legacy key', () async {
    final route = _route();
    // Legacy data: bytes whose derived savedKey is "r…", but stored under the
    // old fallback field-key. This is exactly the state a device carries from
    // an earlier save-format iteration.
    const legacyKey = '||2026-07-11T21:36:41';
    expect(route.savedKey, isNot(legacyKey));
    await HiveStore.putSavedPlan(legacyKey, route.raw!);

    final bloc = PlanBloc();
    addTearDown(bloc.close);
    await bloc.stream.firstWhere((s) => s.savedRoutes.isNotEmpty);
    expect(bloc.state.savedRoutes, hasLength(1));

    // Tap un-save on the card the list actually shows (derived key "r…").
    bloc.add(RouteSaveToggled(bloc.state.savedRoutes.first));
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(bloc.state.savedRoutes, isEmpty);
    expect(HiveStore.savedPlanEntries, isEmpty);
  });
}
