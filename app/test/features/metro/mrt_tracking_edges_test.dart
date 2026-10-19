import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:wheres_the_bus/core/errors/app_error.dart';
import 'package:wheres_the_bus/core/storage/hive_store.dart';
import 'package:wheres_the_bus/data/models/journey_info.dart';
import 'package:wheres_the_bus/data/models/metro_models.dart';
import 'package:wheres_the_bus/data/models/mrt_track_models.dart';
import 'package:wheres_the_bus/data/repositories/mrt_repository.dart';
import 'package:wheres_the_bus/data/repositories/mrt_track_repository.dart';
import 'package:wheres_the_bus/features/metro/bloc/metro_eta_state.dart';
import 'package:wheres_the_bus/features/metro/bloc/metro_state.dart';
import 'package:wheres_the_bus/features/metro/bloc/mrt_track_bloc.dart';
import 'package:wheres_the_bus/features/metro/bloc/mrt_track_event.dart';
import 'package:wheres_the_bus/features/metro/bloc/mrt_track_state.dart';
import 'package:wheres_the_bus/features/metro/data/mrt_board_eta.dart';

import '../../support/helpers/i18n.dart';

MrtTrackSession session({
  String id = 'track',
  String trip = '215',
  String line = 'BL',
  String target = '善導寺',
  MrtTrackStatus status = MrtTrackStatus.tracking,
}) => MrtTrackSession.fromJson({
  'trackId': id,
  'tripId': trip,
  'status': status.name,
  'pathStationIds': ['${line}12', '${line}13'],
  'pathStationNames': ['臺北車站', target],
  'targetIndex': 1,
});

MetroArrival arrival({
  String trip = '215',
  String line = 'BL',
  String dest = '',
}) => MetroArrival(
  line: line,
  destination: dest,
  estimateSeconds: 10,
  trainNumber: trip,
);

class _TrackRepository extends MrtTrackRepository {
  final watched = <String>[];
  @override
  Stream<MrtTrackSession> watch(String id) {
    watched.add(id);
    return const Stream.empty();
  }
}

class _BoardRepository extends MrtRepository {
  String? requestedSystem;
  String? requestedStation;
  @override
  Stream<MetroLiveArrival> eta(String system, String stationId) {
    requestedSystem = system;
    requestedStation = stationId;
    return Stream.fromIterable([
      const MetroLiveArrival(
        line: 'BL',
        destination: '',
        estimateSeconds: 90,
        trainNumber: 'other',
      ),
      const MetroLiveArrival(
        line: 'BL',
        destination: '',
        estimateSeconds: 60,
        trainNumber: '215',
      ),
      const MetroLiveArrival(
        line: 'BL',
        destination: '',
        estimateSeconds: 0,
        trainNumber: '215',
      ),
    ]);
  }
}

void main() {
  test('every tracking status survives saving and decoding', () {
    for (final status in MrtTrackStatus.values) {
      final original = session(status: status);
      final json = original.toJson();
      expect(MrtTrackSession.fromJson(json), original);
      expect(original.status, status);
      expect(
        json['status'],
        status == MrtTrackStatus.leadFired ? 'lead_fired' : status.name,
      );
    }
    expect(MrtTrackStatus.fromWire('leadFired'), MrtTrackStatus.leadFired);
    expect(MrtTrackStatus.fromWire('future_status'), MrtTrackStatus.cancelled);
  });

  test('arrival bells match an active line and identified train', () {
    expect(const MrtTrackBlocState().tracks(arrival()), isFalse);
    for (final status in MrtTrackStatus.values) {
      final state = MrtTrackBlocState(session: session(status: status));
      expect(state.tracks(arrival()), !status.isTerminal);
    }
    final state = MrtTrackBlocState(session: session());
    expect(state.tracks(arrival(line: 'R')), isFalse);
    expect(state.tracks(arrival(trip: 'other')), isFalse);
    expect(state.tracks(arrival(trip: '')), isTrue);
    final anonymous = MrtTrackBlocState(
      session: session(trip: '', target: ''),
    );
    expect(anonymous.tracks(arrival(trip: '')), isFalse);
    expect(anonymous.tracks(arrival(trip: '', dest: '南港')), isTrue);
  });

  test(
    'metro snapshots keep omitted values and independently clear each field',
    () {
      const info = JourneyInfo(
        toStationId: 'BL13',
        fareNt: 20,
        halfFareNt: 10,
        travelTimeMin: 2,
      );
      const original = MetroState(
        activeStationId: 'BL12',
        journeyMatrix: {'BL13': info},
        error: OfflineError(),
      );
      expect(original.copyWith(), original);
      final updated = original.copyWith(
        activeStationId: 'BL13',
        journeyMatrix: const {},
        error: const OfflineError(),
      );
      expect(updated.activeStationId, 'BL13');
      expect(updated.journeyMatrix, isEmpty);
      expect(
        original.copyWith(
          clearStation: true,
          clearMatrix: true,
          clearError: true,
        ),
        const MetroState(),
      );
    },
  );

  test(
    'boarding feed ignores other train numbers and forwards arrival seconds',
    () async {
      final repository = _BoardRepository();
      expect(
        await defaultBoardEtaStream(
          system: 'TRTC',
          stationId: 'BL12',
          trainNumber: '',
          repository: repository,
        ).toList(),
        isEmpty,
      );
      expect(repository.requestedStation, isNull);
      final values = await defaultBoardEtaStream(
        system: 'TRTC',
        stationId: 'BL12',
        trainNumber: '215',
        repository: repository,
      ).take(2).toList();
      expect(values, [60, 0]);
      expect(repository.requestedSystem, 'TRTC');
      expect(repository.requestedStation, 'BL12');
    },
  );

  group('persisted tracking', () {
    late Box<dynamic> settings;
    setUp(
      () async => settings = await Hive.openBox<dynamic>(
        'settings',
        bytes: Uint8List(0),
      ),
    );
    tearDown(() => settings.close());
    MrtTrackBloc make(_TrackRepository repository) => MrtTrackBloc(
      i18n: zhStrings,
      repository: repository,
      liveActivityEnabled: () => false,
    );

    test('missing persisted data leaves an idle session', () async {
      final repository = _TrackRepository();
      final bloc = make(repository);
      addTearDown(bloc.close);
      bloc.add(const MrtTrackRestored());
      await pumpEventQueue();
      expect(bloc.state.session, isNull);
      expect(repository.watched, isEmpty);
    });

    test('empty or terminal persisted tracks are discarded', () async {
      for (final saved in [
        session(id: ''),
        session(status: MrtTrackStatus.arrived),
      ]) {
        await HiveStore.putMrtTrackSession(saved.toJson());
        final repository = _TrackRepository();
        final bloc = make(repository)..add(const MrtTrackRestored());
        await pumpEventQueue();
        expect(HiveStore.mrtTrackSession, isNull);
        expect(bloc.state.session, isNull);
        expect(repository.watched, isEmpty);
        await bloc.close();
      }
    });

    test('live saved tracks resume once without pre-boarding data', () async {
      final saved = session(status: MrtTrackStatus.leadFired);
      await HiveStore.putMrtTrackSession(saved.toJson());
      final repository = _TrackRepository();
      final bloc = make(repository);
      addTearDown(bloc.close);
      bloc.add(const MrtTrackRestored());
      await pumpEventQueue();
      expect(bloc.state.session, saved);
      expect(bloc.state.boardEtaSeconds, isNull);
      expect(repository.watched, ['track']);
      bloc.add(const MrtTrackRestored());
      await pumpEventQueue();
      expect(repository.watched, ['track']);
    });
  });
}
