import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/repositories/near_repository.dart';
import 'package:wheres_the_bus/features/home/bloc/nearby_bloc.dart';
import 'package:wheres_the_bus/features/home/bloc/nearby_event.dart';
import 'package:wheres_the_bus/features/home/bloc/nearby_state.dart';

NearStationViewModel _vm(String id, int distance) => NearStationViewModel(
  type: NearStationType.bus,
  stationId: id,
  stationName: id,
  lat: 25,
  lon: 121.5,
  walkingMinutes: 1,
  distanceMeters: distance,
);

void main() {
  test('loads and sorts stations by distance', () async {
    final repository = _FakeNearRepository([
      _vm('far', 900),
      _vm('near', 100),
      _vm('mid', 400),
    ]);
    final bloc = NearbyBloc(repository: repository);
    addTearDown(bloc.close);

    bloc.add(const NearbyRequested(radius: 800, lat: 25, lon: 121.5));

    await expectLater(
      bloc.stream,
      emitsThrough(
        isA<NearbyState>()
            .having((s) => s.loading, 'loading', isFalse)
            .having((s) => s.error, 'error', isNull)
            .having(
              (s) => s.stations.map((e) => e.stationId).toList(),
              'stations',
              ['near', 'mid', 'far'],
            ),
      ),
    );
  });

  test('surfaces repository errors as AppError', () async {
    final bloc = NearbyBloc(repository: _FakeNearRepository.throwing());
    addTearDown(bloc.close);

    bloc.add(const NearbyRequested(radius: 800, lat: 25, lon: 121.5));

    await expectLater(
      bloc.stream,
      emitsThrough(
        isA<NearbyState>()
            .having((s) => s.loading, 'loading', isFalse)
            .having((s) => s.error, 'error', isNotNull),
      ),
    );
  });

  test('successive queries share one bidirectional stream', () async {
    final repository = _FakeNearRepository([_vm('only', 100)]);
    final bloc = NearbyBloc(repository: repository);
    addTearDown(bloc.close);

    bloc
      ..add(const NearbyRequested(radius: 800, lat: 25, lon: 121.5))
      ..add(const NearbyRequested(radius: 900, lat: 25.1, lon: 121.6));
    await pumpEventQueue();

    expect(repository.streamsOpened, 1);
    expect(repository.queries.length, 2);
  });

  test('the newest response on the stream is the one kept', () async {
    final repository = _FakeNearRepository.perQuery([
      [_vm('first', 100)],
      [_vm('second', 200)],
    ]);
    final bloc = NearbyBloc(repository: repository);
    addTearDown(bloc.close);

    bloc
      ..add(const NearbyRequested(radius: 800, lat: 25, lon: 121.5))
      ..add(const NearbyRequested(radius: 900, lat: 25.1, lon: 121.6));
    await pumpEventQueue();

    expect(bloc.state.stations.map((e) => e.stationId).toList(), ['second']);
    expect(bloc.state.error, isNull);
  });

  test('a broken stream is replaced on the next query', () async {
    final repository = _FakeNearRepository.throwing();
    final bloc = NearbyBloc(repository: repository);
    addTearDown(bloc.close);

    bloc.add(const NearbyRequested(radius: 800, lat: 25, lon: 121.5));
    await bloc.stream.firstWhere((s) => s.error != null);
    // Two: the failing query plus the one automatic replay a dropped stream
    // earns before the error is reported — see NearbyBloc._onStreamFailed.
    expect(repository.streamsOpened, 2);

    repository
      ..shouldThrow = false
      ..result = [_vm('recovered', 50)];
    bloc.add(const NearbyRequested(radius: 800, lat: 25, lon: 121.5));

    final loaded = await bloc.stream.firstWhere(
      (s) => !s.loading && s.error == null && s.stations.isNotEmpty,
    );
    expect(loaded.stations.single.stationId, 'recovered');
    expect(repository.streamsOpened, 3);
  });

  test(
    'retry re-queries the last attempted (dragged) viewport, not device GPS',
    () async {
      final repository = _FakeNearRepository.throwing();
      final bloc = NearbyBloc(repository: repository);
      addTearDown(bloc.close);

      bloc.add(const NearbyRequested(radius: 500, lat: 25.2, lon: 121.7));
      await bloc.stream.firstWhere((s) => s.error != null);

      repository
        ..shouldThrow = false
        ..result = [_vm('retried', 50)];
      bloc.add(const NearbyRetried());

      final loaded = await bloc.stream.firstWhere(
        (s) => !s.loading && s.error == null && s.stations.isNotEmpty,
      );

      expect(repository.queries.last, (25.2, 121.7, 500));
      expect(loaded.stations.single.stationId, 'retried');
    },
  );

  test(
    'a stream dropped with nothing in flight keeps the loaded list',
    () async {
      final repository = _FakeNearRepository([_vm('loaded', 100)]);
      final bloc = NearbyBloc(repository: repository);
      addTearDown(bloc.close);

      bloc.add(const NearbyRequested(radius: 800, lat: 25, lon: 121.5));
      await bloc.stream.firstWhere((s) => !s.loading && s.stations.isNotEmpty);

      // The rider is on another page; the connection under the idle stream is
      // dropped. Nothing asked anything, so nothing failed.
      repository.dropStream();
      await pumpEventQueue();

      expect(bloc.state.error, isNull);
      expect(bloc.state.stations.single.stationId, 'loaded');

      // The next viewport query opens a fresh stream on its own.
      bloc.add(const NearbyRequested(radius: 800, lat: 25.01, lon: 121.5));
      await pumpEventQueue();
      expect(repository.streamsOpened, 2);
    },
  );

  test('a stream dropped mid-query replays that query once', () async {
    final repository = _FakeNearRepository([_vm('replayed', 100)])
      ..holdResponses = true;
    final bloc = NearbyBloc(repository: repository);
    addTearDown(bloc.close);

    bloc.add(const NearbyRequested(radius: 500, lat: 25.2, lon: 121.7));
    await pumpEventQueue();
    repository
      ..dropStream()
      ..holdResponses = false;

    final loaded = await bloc.stream.firstWhere(
      (s) => !s.loading && s.stations.isNotEmpty,
    );
    expect(loaded.error, isNull);
    expect(loaded.stations.single.stationId, 'replayed');
    expect(repository.queries.last, (25.2, 121.7, 500));
    expect(repository.streamsOpened, 2);
  });

  test('a second failure in a row surfaces the error', () async {
    final repository = _FakeNearRepository([])..holdResponses = true;
    final bloc = NearbyBloc(repository: repository);
    addTearDown(bloc.close);

    bloc.add(const NearbyRequested(radius: 500, lat: 25.2, lon: 121.7));
    await pumpEventQueue();
    repository.dropStream();
    await pumpEventQueue();
    repository.dropStream();

    final failed = await bloc.stream.firstWhere((s) => s.error != null);
    expect(failed.loading, isFalse);
  });

  test('stays empty and loading until the first response arrives', () async {
    final repository = _FakeNearRepository([_vm('live', 100)])
      ..holdResponses = true;
    final bloc = NearbyBloc(repository: repository);
    addTearDown(bloc.close);

    bloc.add(const NearbyRequested(radius: 800, lat: 25, lon: 121.5));
    await pumpEventQueue();

    expect(bloc.state.stations, isEmpty);
    expect(bloc.state.loading, isTrue);

    repository.holdResponses = false;
    bloc.add(const NearbyRequested(radius: 800, lat: 25, lon: 121.5));
    await bloc.stream.firstWhere((s) => !s.loading);

    expect(bloc.state.stations.single.stationId, 'live');
  });

  test('retry is a no-op before any query has been attempted', () async {
    final bloc = NearbyBloc(repository: _FakeNearRepository([]));
    addTearDown(bloc.close);

    bloc.add(const NearbyRetried());
    await pumpEventQueue();

    expect(bloc.state, const NearbyState());
  });
}

class _FakeNearRepository implements NearRepository {
  _FakeNearRepository(this.result) : shouldThrow = false;
  _FakeNearRepository.throwing() : result = const [], shouldThrow = true;

  /// Answers the nth query with the nth entry, so a test can tell responses
  /// apart on a stream that carries several.
  _FakeNearRepository.perQuery(this._perQuery)
    : result = const [],
      shouldThrow = false;

  List<NearStationViewModel> result;
  bool shouldThrow;
  List<List<NearStationViewModel>>? _perQuery;

  /// Records queries without answering them, so a test can hold one in flight.
  bool holdResponses = false;

  /// How many times [near] was called — i.e. how many streams the bloc opened.
  int streamsOpened = 0;
  final queries = <(double, double, int)>[];

  StreamController<List<NearStationViewModel>>? _open;

  /// Breaks the open stream the way a dropped connection does — an error on
  /// the response side, unprompted by any request.
  void dropStream() => _open?.addError(Exception('connection terminated'));

  @override
  Stream<List<NearStationViewModel>> near(Stream<NearQuery> requests) {
    streamsOpened++;
    final responses = StreamController<List<NearStationViewModel>>();
    _open = responses;
    final subscription = requests.listen((q) {
      queries.add((q.lat, q.lon, q.radius));
      if (shouldThrow) {
        responses.addError(Exception('boom'));
        return;
      }
      if (holdResponses) return;
      final scripted = _perQuery;
      responses.add(scripted == null ? result : scripted[queries.length - 1]);
    });
    responses.onCancel = subscription.cancel;
    return responses.stream;
  }

  @override
  Stream<List<NearStationViewModel>> nearOnce(
    double lat,
    double lon,
    int radius,
  ) async* {
    queries.add((lat, lon, radius));
    if (shouldThrow) throw Exception('boom');
    yield result;
  }
}
