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

  test(
    'search success enters results phase with the fastest selected',
    () async {
      final result = PlanResult(routes: [_route(), _route()]);
      final bloc = PlanBloc(repository: _FakeMaasRepository(result: result));
      addTearDown(bloc.close);

      final next = expectLater(
        bloc.stream,
        emitsThrough(
          isA<PlanState>()
              .having((s) => s.status, 'status', PlanStatus.success)
              .having((s) => s.selectedRouteIndex, 'selectedRouteIndex', 0)
              .having((s) => s.previewing, 'previewing', false),
        ),
      );

      bloc.add(_search());
      await next;
    },
  );

  test('selecting a route enters the preview phase', () async {
    final bloc = PlanBloc(repository: _FakeMaasRepository());
    addTearDown(bloc.close);

    final next = expectLater(
      bloc.stream,
      emitsThrough(
        isA<PlanState>()
            .having((s) => s.selectedRouteIndex, 'selectedRouteIndex', 2)
            .having((s) => s.previewing, 'previewing', true),
      ),
    );

    bloc.add(const RouteSelected(index: 2));
    await next;
  });

  test(
    'closing a results preview returns to results, keeping the result',
    () async {
      final result = PlanResult(routes: [_route(), _route()]);
      final bloc = PlanBloc(repository: _FakeMaasRepository(result: result));
      addTearDown(bloc.close);

      bloc.add(_search());
      await bloc.stream.firstWhere((s) => s.status == PlanStatus.success);
      bloc.add(const RouteSelected(index: 1));
      await bloc.stream.firstWhere((s) => s.previewing);

      final next = expectLater(
        bloc.stream,
        emitsThrough(
          isA<PlanState>()
              .having((s) => s.previewing, 'previewing', false)
              .having((s) => s.result, 'result', result)
              .having((s) => s.selectedRouteIndex, 'selectedRouteIndex', 1),
        ),
      );

      bloc.add(const PreviewClosed());
      await next;
    },
  );

  test('a new search resets an active preview back to results', () async {
    final bloc = PlanBloc(
      repository: _FakeMaasRepository(result: PlanResult(routes: [_route()])),
    );
    addTearDown(bloc.close);

    bloc.add(const RouteSelected(index: 0));
    await bloc.stream.firstWhere((s) => s.previewing);

    final next = expectLater(
      bloc.stream,
      emitsThrough(
        isA<PlanState>()
            .having((s) => s.status, 'status', PlanStatus.success)
            .having((s) => s.previewing, 'previewing', false),
      ),
    );

    bloc.add(_search());
    await next;
  });

  test('opening a saved route lands directly in preview', () async {
    final bloc = PlanBloc(repository: _FakeMaasRepository());
    addTearDown(bloc.close);

    final next = expectLater(
      bloc.stream,
      emitsThrough(
        isA<PlanState>()
            .having((s) => s.status, 'status', PlanStatus.success)
            .having((s) => s.previewing, 'previewing', true)
            .having((s) => s.previewFromSaved, 'previewFromSaved', true)
            .having((s) => s.result?.routes.length, 'routes', 1),
      ),
    );

    bloc.add(SavedRouteOpened(_route()));
    await next;
  });

  test('closing a saved-route preview clears the injected result', () async {
    final bloc = PlanBloc(repository: _FakeMaasRepository());
    addTearDown(bloc.close);

    bloc.add(SavedRouteOpened(_route()));
    await bloc.stream.firstWhere((s) => s.previewing);

    final next = expectLater(
      bloc.stream,
      emitsThrough(
        isA<PlanState>()
            .having((s) => s.status, 'status', PlanStatus.initial)
            .having((s) => s.result, 'result', null)
            .having((s) => s.previewing, 'previewing', false)
            .having((s) => s.previewFromSaved, 'previewFromSaved', false),
      ),
    );

    bloc.add(const PreviewClosed());
    await next;
  });

  test('ending navigation returns to the previewed route', () async {
    final result = PlanResult(routes: [_route(), _route()]);
    final bloc = PlanBloc(repository: _FakeMaasRepository(result: result));
    addTearDown(bloc.close);

    bloc.add(_search());
    await bloc.stream.firstWhere((s) => s.status == PlanStatus.success);
    bloc.add(const RouteSelected(index: 1));
    await bloc.stream.firstWhere((s) => s.previewing);
    bloc.add(const NavigationStarted());
    await bloc.stream.firstWhere((s) => s.activeLegIndex != null);

    final next = expectLater(
      bloc.stream,
      emitsThrough(
        isA<PlanState>()
            .having((s) => s.activeLegIndex, 'activeLegIndex', null)
            .having((s) => s.previewing, 'previewing', true)
            .having((s) => s.selectedRouteIndex, 'selectedRouteIndex', 1),
      ),
    );

    bloc.add(const NavigationEnded());
    await next;
  });

  test('navigation events update and clear active indexes', () async {
    final bloc = PlanBloc(repository: _FakeMaasRepository());
    addTearDown(bloc.close);

    bloc
      ..add(const NavigationStarted())
      ..add(const StopArrived(legIndex: 1, stopIndex: 3))
      ..add(const NavigationEnded());

    await expectLater(
      bloc.stream,
      emitsInOrder([
        // The constructor's SavedRoutesLoaded emits first; skip past it.
        emitsThrough(
          isA<PlanState>().having((s) => s.activeLegIndex, 'activeLegIndex', 0),
        ),
        isA<PlanState>().having((s) => s.activeStopIndex, 'activeStopIndex', 3),
        isA<PlanState>().having(
          (s) => s.activeLegIndex,
          'activeLegIndex',
          null,
        ),
      ]),
    );
  });
}

PlanSearchRequested _search() => const PlanSearchRequested(
  fromLat: 25,
  fromLon: 121,
  toLat: 25.1,
  toLon: 121.1,
  date: '2026-07-03',
  time: '12:00',
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
  }) async* {
    final error = this.error;
    if (error != null) throw error;
    if (staged) yield (result: result, complete: false);
    yield (result: result, complete: true);
  }
}
