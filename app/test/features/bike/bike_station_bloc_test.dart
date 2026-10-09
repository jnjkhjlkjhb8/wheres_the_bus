import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart';
import 'package:wheres_the_bus/core/errors/app_error.dart';
import 'package:wheres_the_bus/data/models/bike_models.dart';
import 'package:wheres_the_bus/data/repositories/bike_repository.dart';
import 'package:wheres_the_bus/features/bike/bloc/bike_station_bloc.dart';
import 'package:wheres_the_bus/features/bike/bloc/bike_station_event.dart';

void main() {
  test('BikeStationBloc starts in loading state', () {
    final bloc = BikeStationBloc(stationUid: 'bike-tpe');
    addTearDown(bloc.close);
    expect(bloc.state.loading, isTrue);
    expect(bloc.state.available, 0);
  });

  test(
    'a real availability frame sets hasLiveData, distinguishing a '
    'confirmed zero from no data yet (F27)',
    () async {
      const zero = BikeAvailability(
        generalBikes: 0,
        electricBikes: 0,
        returnDocks: 3,
      );
      final repository = _FakeBikeRepository(
        etaSource: () => Stream.value(zero),
      );
      final bloc = BikeStationBloc(
        stationUid: 'bike-tpe',
        repository: repository,
      );
      addTearDown(bloc.close);

      final state = await bloc.stream.firstWhere((s) => s.hasLiveData);
      expect(state.available, 0);
      expect(state.hasLiveData, isTrue);
      expect(state.liveError, isNull);
    },
  );

  test(
    'a static-info fetch failure surfaces on state.error',
    () async {
      final repository = _FakeBikeRepository(
        staticThrows: true,
        etaSource: Stream<BikeAvailability>.empty,
      );
      final bloc = BikeStationBloc(
        stationUid: 'bike-tpe',
        repository: repository,
      );
      addTearDown(bloc.close);

      final state = await bloc.stream.firstWhere((s) => !s.loading);
      expect(state.error, isNotNull);
    },
  );

  test(
    'a live stream failure surfaces on state.liveError without needing a '
    'static-info failure (F27)',
    () async {
      final repository = _FakeBikeRepository(
        etaSource: () =>
            Stream<BikeAvailability>.error(const GrpcError.unauthenticated()),
      );
      final bloc = BikeStationBloc(
        stationUid: 'bike-tpe',
        repository: repository,
      );
      addTearDown(bloc.close);

      final state = await bloc.stream.firstWhere((s) => s.liveError != null);
      expect(state.error, isNull);
      expect(state.hasLiveData, isFalse);
      expect(state.liveError, isA<AppError>());
    },
  );

  test(
    'a real live frame clears a prior liveError, not just the recovery '
    'callback — the two must not race into a stuck error',
    () async {
      final repository = _FakeBikeRepository(
        etaSource: Stream<BikeAvailability>.empty,
      );
      final bloc = BikeStationBloc(
        stationUid: 'bike-tpe',
        repository: repository,
      );
      addTearDown(bloc.close);

      await bloc.stream.firstWhere((s) => !s.loading);
      bloc.add(const BikeStationEtaFailed(OfflineError()));
      await bloc.stream.firstWhere((s) => s.liveError != null);

      bloc.add(
        const BikeStationEtaUpdated(
          available: 3,
          returnDocks: 4,
          generalBikes: 2,
          electricBikes: 1,
        ),
      );
      final recovered = await bloc.stream.firstWhere(
        (s) => s.liveError == null && s.hasLiveData,
      );
      expect(recovered.available, 3);
    },
  );

  test(
    'a static fetch with no landed point keeps the caller-seeded coordinates '
    'instead of overwriting them with 0/0',
    () async {
      final repository = _FakeBikeRepository(
        etaSource: Stream<BikeAvailability>.empty,
        staticLat: 0,
        staticLon: 0,
      );
      final bloc = BikeStationBloc(
        stationUid: 'bike-tpe',
        repository: repository,
        lat: 24.9928,
        lon: 121.3009,
      );
      addTearDown(bloc.close);

      final state = await bloc.stream.firstWhere((s) => !s.loading);
      expect(state.lat, 24.9928);
      expect(state.lon, 121.3009);
    },
  );

  test('a static fetch that does carry a point wins over the seed', () async {
    final repository = _FakeBikeRepository(
      etaSource: Stream<BikeAvailability>.empty,
    );
    final bloc = BikeStationBloc(
      stationUid: 'bike-tpe',
      repository: repository,
      lat: 1,
      lon: 2,
    );
    addTearDown(bloc.close);

    final state = await bloc.stream.firstWhere((s) => !s.loading);
    expect(state.lat, 25.033);
    expect(state.lon, 121.565);
  });

  test('close cancels the live subscription before completing (F35)', () async {
    var cancelled = false;
    final controller = StreamController<BikeAvailability>(
      onCancel: () => cancelled = true,
    );
    addTearDown(() async {
      if (!controller.isClosed) await controller.close();
    });
    final repository = _FakeBikeRepository(
      etaSource: () => controller.stream,
    );
    final bloc = BikeStationBloc(
      stationUid: 'bike-tpe',
      repository: repository,
    );
    await bloc.stream.firstWhere((s) => !s.loading);

    await bloc.close();

    expect(cancelled, isTrue);
  });
}

class _FakeBikeRepository implements BikeRepository {
  _FakeBikeRepository({
    required this.etaSource,
    this.staticThrows = false,
    this.staticLat = 25.033,
    this.staticLon = 121.565,
  });

  final Stream<BikeAvailability> Function() etaSource;
  final bool staticThrows;
  final double staticLat;
  final double staticLon;

  @override
  Future<BikeStationInfo> stationStatic(String stationUid) async {
    if (staticThrows) throw const GrpcError.unavailable();
    return BikeStationInfo(
      name: '測試站',
      capacity: 10,
      lat: staticLat,
      lon: staticLon,
    );
  }

  @override
  Stream<BikeAvailability> stationEta(String stationUid) => etaSource();

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} not faked');
}
