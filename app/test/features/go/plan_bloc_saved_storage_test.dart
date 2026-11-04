import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:wheres_the_bus/core/storage/hive_store.dart';
import 'package:wheres_the_bus/data/models/plan_models.dart';
import 'package:wheres_the_bus/data/repositories/maas_repository.dart';
import 'package:wheres_the_bus/features/go/bloc/plan_bloc.dart';
import 'package:wheres_the_bus/features/go/bloc/plan_event.dart';
import 'package:wheres_the_bus/features/go/bloc/plan_state.dart';

// Kept out of plan_bloc_test.dart: opening a real saved_plans box here must
// not leak into the tests that rely on storage being unavailable.
class _NoPlans implements MaasRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _route = PlanRoute(
  travelTime: 600,
  startTime: '12:00',
  endTime: '12:10',
  transfers: 0,
  sections: [],
);

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('plan_bloc_saved'));
  tearDown(() async {
    await Hive.close();
    dir.deleteSync(recursive: true);
  });

  test('unavailable storage is reported as a load error', () async {
    final bloc = PlanBloc(repository: _NoPlans());
    addTearDown(bloc.close);

    final state = await bloc.stream.first;

    expect(state.savedRoutesReady, isFalse);
    expect(state.savedRoutesLoadError, isTrue);
  });

  test('a toggle that finds storage gone reports the load error', () async {
    Hive.init(dir.path);
    await Hive.openBox<dynamic>('saved_plans');
    final bloc = PlanBloc(repository: _NoPlans());
    addTearDown(bloc.close);
    final loaded = await bloc.stream.firstWhere((s) => s.savedRoutesReady);
    expect(loaded.savedRoutesLoadError, isFalse);

    await Hive.box<dynamic>('saved_plans').close();
    bloc.add(const RouteSaveToggled(_route));

    final failed = await bloc.stream.firstWhere((s) => s.savedRoutesLoadError);
    expect(failed.savedRoutesReady, isFalse);
  });

  testWidgets('a storage open that never completes times out to load error', (
    tester,
  ) async {
    unawaited(HiveStore.init(initBinding: () => Completer<void>().future));
    final bloc = PlanBloc(repository: _NoPlans());
    addTearDown(bloc.close);
    PlanState? last;
    final sub = bloc.stream.listen((s) => last = s);
    addTearDown(sub.cancel);

    await tester.pump(const Duration(seconds: 6));

    expect(last?.savedRoutesLoadError, isTrue);
    expect(last?.savedRoutesReady, isFalse);
  });
}
