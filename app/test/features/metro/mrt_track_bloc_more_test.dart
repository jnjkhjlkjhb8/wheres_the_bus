import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:wheres_the_bus/core/live_activity/alight_track.dart';
import 'package:wheres_the_bus/core/storage/hive_store.dart';
import 'package:wheres_the_bus/data/models/mrt_track_models.dart';
import 'package:wheres_the_bus/data/repositories/mrt_track_repository.dart';
import 'package:wheres_the_bus/features/metro/bloc/mrt_track_bloc.dart';
import 'package:wheres_the_bus/features/metro/bloc/mrt_track_event.dart';
import 'package:wheres_the_bus/features/metro/bloc/mrt_track_state.dart';

import '../../support/helpers/i18n.dart';

MrtTrackSession _session({
  String trackId = 't1',
  int remainingStops = 3,
  int targetIndex = 3,
  MrtTrackStatus status = MrtTrackStatus.tracking,
}) => MrtTrackSession(
  trackId: trackId,
  tripId: '215',
  carId: '1163',
  pathStationIds: const ['BL12', 'BL13', 'BL14', 'BL18'],
  pathStationNames: const ['台北車站', '善導寺', '忠孝新生', '市政府'],
  targetIndex: targetIndex,
  currentIndex: 0,
  remainingStops: remainingStops,
  nextStationId: 'BL13',
  nextStationName: '善導寺',
  progress: 0,
  status: status,
  leadStops: 1,
  system: 'TRTC',
);

const _request = MrtTrackRequested(
  carId: '1163',
  boardStationId: 'BL12',
  destStationId: 'BL23',
  targetStationId: 'BL18',
  leadStops: 1,
  trainNumber: '215',
);

class _Channel extends AlightTrackChannel {
  final started = <AlightTrackContent>[];
  final updates = <AlightTrackContent>[];

  @override
  Future<int> start(AlightTrackContent content) async {
    started.add(content);
    return started.length;
  }

  @override
  Future<void> update(int lease, AlightTrackContent content) async =>
      updates.add(content);

  @override
  Future<void> stop(int lease) async {}
}

class _Repo extends MrtTrackRepository {
  MrtTrackSession? created;
  Object? createError;
  Object? cancelError;
  Object? tokenError;
  final watches = <StreamController<MrtTrackSession>>[];

  @override
  Future<MrtTrackSession> createTrack({
    required String carId,
    required String boardStationId,
    required String destStationId,
    required String targetStationId,
    required int leadStops,
    String vehicleLabel = '',
    String lineCode = '',
    String lineColorHex = '',
  }) async {
    final err = createError;
    // ignore: only_throw_errors — mirrors the errors the seam surfaces.
    if (err != null) throw err;
    return created!;
  }

  @override
  Future<void> cancel(String trackId) async {
    final err = cancelError;
    // ignore: only_throw_errors — mirrors the errors the seam surfaces.
    if (err != null) throw err;
  }

  @override
  Future<void> setPushToken(String trackId, String token) async {
    final err = tokenError;
    // ignore: only_throw_errors — mirrors the errors the seam surfaces.
    if (err != null) throw err;
  }

  @override
  Stream<MrtTrackSession> watch(String trackId) {
    final c = StreamController<MrtTrackSession>();
    watches.add(c);
    return c.stream;
  }
}

void main() {
  late List<Object> reported;
  late _Repo repo;
  late _Channel channel;
  late List<StreamController<int>> boardFeeds;

  setUp(() {
    reported = [];
    repo = _Repo()..created = _session();
    channel = _Channel();
    boardFeeds = [];
  });

  MrtTrackBloc build({bool activity = false}) {
    final bloc = MrtTrackBloc(
      i18n: zhStrings,
      repository: repo,
      channel: channel,
      liveActivityEnabled: () => activity,
      vibrate: (_, _) async {},
      reportError: (e, _) => reported.add(e),
      boardEtaStream:
          ({required system, required stationId, required trainNumber}) {
            final c = StreamController<int>();
            boardFeeds.add(c);
            return c.stream;
          },
    );
    addTearDown(bloc.close);
    return bloc;
  }

  Future<MrtTrackBloc> started({bool activity = false}) async {
    final bloc = build(activity: activity)..add(_request);
    await bloc.stream.firstWhere((s) => s.session != null);
    await pumpEventQueue();
    return bloc;
  }

  test(
    'an unexpected create failure is reported and shown as generic',
    () async {
      repo.createError = StateError('boom');
      final bloc = build()..add(_request);
      await pumpEventQueue();
      expect(reported.single, isA<StateError>());
      expect(bloc.state.creating, isFalse);
      expect(bloc.state.createError, MrtTrackCreateError.generic);
    },
  );

  test('a failed cancel call and a failed token upload are reported', () async {
    final bloc = await started();
    repo.tokenError = StateError('token');
    bloc.add(const MrtTrackPushTokenReceived('abc'));
    await pumpEventQueue();
    expect(reported.single, isA<StateError>());

    repo.cancelError = StateError('cancel');
    bloc.add(const MrtTrackCancelled());
    await pumpEventQueue();
    expect(reported, hasLength(2));
    expect(bloc.state.session, isNull);
  });

  test('a session that is already over is not adopted', () async {
    repo.created = _session(status: MrtTrackStatus.arrived);
    final bloc = build()..add(_request);
    await pumpEventQueue();
    expect(bloc.state.session, isNull);
    expect(bloc.state.creating, isFalse);
    expect(repo.watches, isEmpty);
  });

  test('adopting another session drops the previous watch', () async {
    final bloc = await started();
    expect(repo.watches, hasLength(1));
    expect(repo.watches.first.hasListener, isTrue);
    repo.created = _session(trackId: 't2');
    bloc.add(_request);
    await bloc.stream.firstWhere((s) => s.session?.trackId == 't2');
    await pumpEventQueue();
    expect(repo.watches, hasLength(2));
    expect(repo.watches.first.hasListener, isFalse);
    expect(repo.watches.last.hasListener, isTrue);
  });

  test('a new boarding feed replaces the previous one', () async {
    final bloc = await started();
    expect(boardFeeds, hasLength(1));
    expect(boardFeeds.first.hasListener, isTrue);
    repo.created = _session(trackId: 't2');
    bloc.add(_request);
    await bloc.stream.firstWhere((s) => s.session?.trackId == 't2');
    await pumpEventQueue();
    expect(boardFeeds, hasLength(2));
    expect(boardFeeds.first.hasListener, isFalse);
  });

  test('boarding readings only count while a session is live', () async {
    final bloc = build()..add(const MrtBoardEtaTicked(120));
    await pumpEventQueue();
    expect(bloc.state.boardEtaSeconds, isNull);

    final live = await started();
    live.add(const MrtBoardEtaTicked(120));
    await pumpEventQueue();
    expect(live.state.boardEtaSeconds, 120);
  });

  test('a live update is saved for the next launch', () async {
    final box = await Hive.openBox<dynamic>('settings', bytes: Uint8List(0));
    addTearDown(box.close);
    final bloc = await started();
    final updated = _session(remainingStops: 2);
    bloc.add(MrtTrackUpdated(updated));
    await pumpEventQueue();
    expect(HiveStore.mrtTrackSession, updated.toJson());
  });

  test('updates without an open settings box do not touch storage', () async {
    final bloc = await started();
    bloc.add(MrtTrackUpdated(_session(remainingStops: 2)));
    await pumpEventQueue();
    expect(bloc.state.session!.remainingStops, 2);
  });

  group('live activity phase', () {
    Future<AlightTrackContent> contentFor(int remaining) async {
      repo.created = _session(remainingStops: remaining);
      await started(activity: true);
      return channel.started.last;
    }

    test('riding until the lead window, approaching inside it', () async {
      expect((await contentFor(3)).phase, AlightTrackPhase.riding);
    });

    test('exactly lead + 1 stops out is already approaching', () async {
      expect((await contentFor(2)).phase, AlightTrackPhase.approaching);
    });

    test('inside the lead window it is approaching', () async {
      expect((await contentFor(1)).phase, AlightTrackPhase.approaching);
    });

    test('a stale ending reads as lost, like a lost one', () async {
      final bloc = await started(activity: true);
      bloc.add(MrtTrackUpdated(_session(status: MrtTrackStatus.stale)));
      await pumpEventQueue();
      expect(channel.updates.last.phase, AlightTrackPhase.lost);
    });

    test('a target at the board station still draws one hop', () async {
      repo.created = _session(targetIndex: 0, remainingStops: 0);
      await started(activity: true);
      expect(channel.started.last.hopCount, 1);
    });

    test('hops follow the target index', () async {
      expect((await contentFor(3)).hopCount, 3);
    });
  });
}
