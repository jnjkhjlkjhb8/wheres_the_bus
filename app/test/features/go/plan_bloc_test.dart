import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/models/plan_models.dart';
import 'package:wheres_the_bus/data/models/plan_options.dart';
import 'package:wheres_the_bus/data/repositories/maas_repository.dart';
import 'package:wheres_the_bus/features/go/bloc/plan_bloc.dart';
import 'package:wheres_the_bus/features/go/bloc/plan_event.dart';
import 'package:wheres_the_bus/features/go/bloc/plan_state.dart';

void main() {
  test('search success emits result', () async {
    final result = PlanResult(routes: [_route()]);
    final bloc = PlanBloc(repository: _FakeMaasRepository(result: result));
    addTearDown(bloc.close);

    final next = expectLater(
      bloc.stream,
      emitsThrough(
        isA<PlanState>()
            .having((s) => s.status, 'status', PlanStatus.success)
            .having((s) => s.result, 'result', result),
      ),
    );

    bloc.add(_search());
    await next;
  });

  test(
    'a stale search resolving after a newer one does not overwrite it',
    () async {
      final firstCompleter = Completer<PlanResult>();
      final secondCompleter = Completer<PlanResult>();
      final repository = _ControlledMaasRepository([
        firstCompleter,
        secondCompleter,
      ]);
      final bloc = PlanBloc(repository: repository);
      addTearDown(bloc.close);

      final firstResult = PlanResult(routes: [_route()]);
      final secondResult = PlanResult(routes: [_route(), _route()]);

      bloc
        ..add(_search())
        ..add(_search());

      // The second, newer search resolves first...
      secondCompleter.complete(secondResult);
      await pumpEventQueue();
      // ...then the stale first search resolves after it.
      firstCompleter.complete(firstResult);
      await pumpEventQueue();

      expect(bloc.state.result, secondResult);
    },
  );

  test('routes land before geometry, then the pending flag clears', () async {
    final result = PlanResult(routes: [_route()]);
    final bloc = PlanBloc(
      repository: _FakeMaasRepository(result: result, staged: true),
    );
    addTearDown(bloc.close);

    final next = expectLater(
      bloc.stream,
      emitsInOrder([
        emitsThrough(
          isA<PlanState>()
              .having((s) => s.status, 'status', PlanStatus.success)
              .having((s) => s.result, 'result', result)
              .having((s) => s.geometryPending, 'geometryPending', true),
        ),
        isA<PlanState>()
            .having((s) => s.status, 'status', PlanStatus.success)
            .having((s) => s.geometryPending, 'geometryPending', false),
      ]),
    );

    bloc.add(_search());
    await next;
  });

  test('cancelling a search drops the RPC and keeps saved routes', () async {
    final repository = _ControlledMaasRepository([Completer<PlanResult>()]);
    final bloc = PlanBloc(repository: repository);
    addTearDown(bloc.close);

    bloc.add(_search());
    await bloc.stream.firstWhere((s) => s.status == PlanStatus.loading);

    final next = expectLater(
      bloc.stream,
      emitsThrough(
        isA<PlanState>()
            .having((s) => s.status, 'status', PlanStatus.initial)
            .having((s) => s.result, 'result', null),
      ),
    );

    bloc.add(const PlanSearchCancelled());
    await next;
    await pumpEventQueue();
    expect(repository.cancelled, isTrue);
  });

  test('search failure emits error state', () async {
    final bloc = PlanBloc(
      repository: _FakeMaasRepository(error: StateError('boom')),
    );
    addTearDown(bloc.close);

    final next = expectLater(
      bloc.stream,
      emitsThrough(
        isA<PlanState>()
            .having((s) => s.status, 'status', PlanStatus.failure)
            .having((s) => s.error, 'error', contains('boom')),
      ),
    );

    bloc.add(_search());
    await next;
  });

  test('a sort change asks the last search again with the new sort', () async {
    final repository = _FakeMaasRepository(
      result: PlanResult(routes: [_route()]),
    );
    final bloc = PlanBloc(repository: repository);
    addTearDown(bloc.close);

    bloc.add(_search(pageCursor: 'later'));
    await bloc.stream.firstWhere((s) => s.status == PlanStatus.success);
    bloc.add(const PlanSortChanged(PlanSort.cheapest));
    await pumpEventQueue();

    expect(repository.calls, hasLength(2));
    final (first, second) = (repository.calls[0], repository.calls[1]);
    expect(first.sort, PlanSort.fastest);
    expect(second.sort, PlanSort.cheapest);
    // Everything but the sort is the same question, so the planner can
    // answer it from its cache.
    expect(second.time, first.time);
    expect(second.date, first.date);
    expect(second.pageCursor, 'later');
  });

  test(
    'a sort change keeps the results on screen until the new order lands',
    () async {
      final resorted = Completer<PlanResult>();
      final repository = _ControlledMaasRepository([
        Completer<PlanResult>()..complete(PlanResult(routes: [_route()])),
        resorted,
      ]);
      final bloc = PlanBloc(repository: repository);
      addTearDown(bloc.close);

      bloc.add(_search());
      final first = await bloc.stream.firstWhere(
        (s) => s.status == PlanStatus.success,
      );
      final seen = <PlanState>[];
      final sub = bloc.stream.listen(seen.add);
      addTearDown(sub.cancel);

      bloc.add(const PlanSortChanged(PlanSort.cheapest));
      await pumpEventQueue();
      expect(bloc.state.status, PlanStatus.success);
      expect(bloc.state.result, first.result);
      expect(bloc.state.sort, PlanSort.cheapest);

      final reordered = PlanResult(routes: [_route(), _route()]);
      resorted.complete(reordered);
      await pumpEventQueue();

      expect(seen.map((s) => s.status), everyElement(PlanStatus.success));
      expect(bloc.state.result, reordered);
      expect(bloc.state.sort, PlanSort.cheapest);
    },
  );

  test('choosing the current sort again asks nothing', () async {
    final repository = _FakeMaasRepository();
    final bloc = PlanBloc(repository: repository);
    addTearDown(bloc.close);

    bloc.add(_search());
    await bloc.stream.firstWhere((s) => s.status == PlanStatus.success);
    bloc.add(const PlanSortChanged(PlanSort.fastest));
    await pumpEventQueue();

    expect(repository.calls, hasLength(1));
  });

  test('a sort chosen before any search only sets the sort', () async {
    final repository = _FakeMaasRepository();
    final bloc = PlanBloc(repository: repository);
    addTearDown(bloc.close);

    bloc.add(const PlanSortChanged(PlanSort.leastWalking));
    await pumpEventQueue();

    expect(repository.calls, isEmpty);
    expect(bloc.state.sort, PlanSort.leastWalking);
    expect(bloc.state.status, PlanStatus.initial);

    bloc.add(_search());
    await bloc.stream.firstWhere((s) => s.status == PlanStatus.success);
    expect(
      repository.calls.single.sort,
      PlanSort.leastWalking,
    );
  });

  test('cancelling keeps the sort but forgets the search', () async {
    final repository = _FakeMaasRepository();
    final bloc = PlanBloc(repository: repository);
    addTearDown(bloc.close);

    bloc.add(_search());
    await bloc.stream.firstWhere((s) => s.status == PlanStatus.success);
    bloc.add(const PlanSortChanged(PlanSort.fewestTransfers));
    await pumpEventQueue();
    bloc.add(const PlanSearchCancelled());
    await bloc.stream.firstWhere((s) => s.status == PlanStatus.initial);
    expect(bloc.state.sort, PlanSort.fewestTransfers);

    bloc.add(const PlanSortChanged(PlanSort.cheapest));
    await pumpEventQueue();
    expect(repository.calls, hasLength(2));
    expect(bloc.state.status, PlanStatus.initial);
  });

  test('only the fastest sort names its first result the fastest', () {
    final two = PlanResult(routes: [_route(), _route()]);
    expect(PlanState(result: two).firstIsFastest, isTrue);
    expect(
      PlanState(
        result: two,
        sort: PlanSort.cheapest,
      ).firstIsFastest,
      isFalse,
    );
    expect(
      PlanState(result: PlanResult(routes: [_route()])).firstIsFastest,
      isFalse,
    );
    expect(const PlanState().firstIsFastest, isFalse);
  });
}

PlanSearchRequested _search({String pageCursor = ''}) => PlanSearchRequested(
  fromLat: 25,
  fromLon: 121,
  toLat: 25.1,
  toLon: 121.1,
  date: '2026-07-03',
  time: '12:00',
  pageCursor: pageCursor,
);

PlanRoute _route() => const PlanRoute(
  travelTime: 600,
  startTime: '12:00',
  endTime: '12:10',
  transfers: 0,
  sections: [],
);

class _ControlledMaasRepository implements MaasRepository {
  _ControlledMaasRepository(this.completers);

  /// Each successive `planStream()` call consumes the next completer in order,
  /// so the two overlapping calls in a test can resolve out of order.
  final List<Completer<PlanResult>> completers;
  var _calls = 0;

  /// Set once a subscription has been cancelled, so a test can assert the
  /// superseded RPC was actually dropped rather than left running.
  bool cancelled = false;

  @override
  Stream<PlanUpdate> planStream({
    required double fromLat,
    required double fromLon,
    required double toLat,
    required double toLon,
    required String date,
    required String time,
    bool arriveBy = false,
    PlanOptions options = const PlanOptions(),
    String pageCursor = '',
    int legAlternatives = 0,
    PlanSort sort = PlanSort.fastest,
  }) {
    final pending = completers[_calls++].future;
    final controller = StreamController<PlanUpdate>();
    controller
      ..onListen = () async {
        final result = await pending;
        if (controller.isClosed) return;
        controller.add((result: result, complete: true));
        await controller.close();
      }
      ..onCancel = () {
        cancelled = true;
      };
    return controller.stream;
  }
}

class _FakeMaasRepository implements MaasRepository {
  _FakeMaasRepository({PlanResult? result, this.error, this.staged = false})
    : result = result ?? const PlanResult(routes: []);

  final PlanResult result;
  final Error? error;

  /// Emit the router's two-message shape (routes, then routes + geometry)
  /// instead of collapsing to a single complete update.
  final bool staged;

  final calls =
      <({String date, String time, String pageCursor, PlanSort sort})>[];

  @override
  Stream<PlanUpdate> planStream({
    required double fromLat,
    required double fromLon,
    required double toLat,
    required double toLon,
    required String date,
    required String time,
    bool arriveBy = false,
    PlanOptions options = const PlanOptions(),
    String pageCursor = '',
    int legAlternatives = 0,
    PlanSort sort = PlanSort.fastest,
  }) async* {
    calls.add((date: date, time: time, pageCursor: pageCursor, sort: sort));
    final error = this.error;
    if (error != null) throw error;
    if (staged) yield (result: result, complete: false);
    yield (result: result, complete: true);
  }
}
