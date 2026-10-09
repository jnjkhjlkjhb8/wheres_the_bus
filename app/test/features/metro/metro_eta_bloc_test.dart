import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart';
import 'package:wheres_the_bus/core/errors/app_error.dart';
import 'package:wheres_the_bus/data/models/metro_models.dart';
import 'package:wheres_the_bus/data/repositories/mrt_repository.dart';
import 'package:wheres_the_bus/features/metro/bloc/metro_eta_bloc.dart';
import 'package:wheres_the_bus/features/metro/bloc/metro_eta_event.dart';
import 'package:wheres_the_bus/features/metro/bloc/metro_eta_state.dart';

void main() {
  test('MetroEtaBloc has empty arrivals initially', () {
    final bloc = MetroEtaBloc();
    addTearDown(bloc.close);
    expect(bloc.state.arrivals, isEmpty);
    expect(bloc.state, isA<MetroEtaState>());
  });

  test(
    'a stream failure that the feed consumes internally still surfaces '
    'as an error, so stale arrivals are not presented as current (F28)',
    () async {
      final repository = _FakeMrtRepository(
        etaSource: () =>
            Stream<MetroLiveArrival>.error(const GrpcError.unauthenticated()),
      );
      final bloc = MetroEtaBloc(repository: repository);
      addTearDown(bloc.close);

      bloc.add(const LoadMetroEta('TRTC', 'BL12'));

      final state = await bloc.stream.firstWhere((s) => s.error != null);
      expect(state.error, isA<AppError>());
    },
  );

  test(
    'a real source arrival clears a prior failure, not just the recovery '
    'callback — the two must not race into a stuck error',
    () async {
      final repository = _FakeMrtRepository(etaSource: Stream.empty);
      final bloc = MetroEtaBloc(repository: repository);
      addTearDown(bloc.close);

      bloc
        ..add(const LoadMetroEta('TRTC', 'BL12'))
        // Simulates the feed's onFailure firing after the resilient
        // subscription gives up, independent of exercising real backoff
        // timing.
        ..add(const MetroEtaFailed(OfflineError()));
      await bloc.stream.firstWhere((s) => s.error != null);

      bloc.add(
        const MetroEtaArrived([
          MetroArrival(
            line: 'BL',
            destination: '南港展覽館',
            estimateSeconds: 120,
          ),
        ]),
      );
      final recovered = await bloc.stream.firstWhere(
        (s) => s.error == null && s.arrivals.isNotEmpty,
      );

      expect(recovered.error, isNull);
      expect(recovered.arrivals.single.destination, '南港展覽館');
    },
  );

  test('MetroEtaRecovered clears a prior failure', () async {
    final repository = _FakeMrtRepository(etaSource: Stream.empty);
    final bloc = MetroEtaBloc(repository: repository);
    addTearDown(bloc.close);

    bloc
      ..add(const LoadMetroEta('TRTC', 'BL12'))
      ..add(const MetroEtaFailed(OfflineError()));
    await bloc.stream.firstWhere((s) => s.error != null);

    bloc.add(const MetroEtaRecovered());
    final recovered = await bloc.stream.firstWhere((s) => s.error == null);

    expect(recovered.error, isNull);
  });

  test('MetroEtaFailed and MetroEtaRecovered carry the expected data', () {
    const failed = MetroEtaFailed(OfflineError());
    expect(failed.error, const OfflineError());
    const recovered = MetroEtaRecovered();
    expect(recovered.props, isEmpty);
  });
}

class _FakeMrtRepository extends MrtRepository {
  _FakeMrtRepository({required this.etaSource});
  final Stream<MetroLiveArrival> Function() etaSource;

  @override
  Stream<MetroLiveArrival> eta(String system, String stationId) => etaSource();

  @override
  Future<List<MetroScheduleEntry>> schedule(
    String system,
    String stationId,
  ) async => [];
}
