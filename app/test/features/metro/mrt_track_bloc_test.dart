import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart';
import 'package:wheres_the_bus/core/live_activity/alight_track.dart';
import 'package:wheres_the_bus/data/models/mrt_track_models.dart';
import 'package:wheres_the_bus/data/repositories/mrt_track_repository.dart';
import 'package:wheres_the_bus/features/metro/bloc/mrt_track_bloc.dart';
import 'package:wheres_the_bus/features/metro/bloc/mrt_track_event.dart';
import 'package:wheres_the_bus/features/metro/bloc/mrt_track_state.dart';

import '../../support/helpers/i18n.dart';

MrtTrackSession _session({
  String trackId = 't1',
  int currentIndex = 0,
  int remainingStops = 3,
  MrtTrackStatus status = MrtTrackStatus.tracking,
}) => MrtTrackSession(
  trackId: trackId,
  tripId: '215',
  carId: '1163',
  pathStationIds: const ['BL12', 'BL13', 'BL14', 'BL18'],
  pathStationNames: const ['台北車站', '善導寺', '忠孝新生', '市政府'],
  targetIndex: 3,
  currentIndex: currentIndex,
  remainingStops: remainingStops,
  nextStationId: 'BL13',
  nextStationName: '善導寺',
  progress: currentIndex / 3,
  status: status,
  leadStops: 1,
  system: 'TRTC',
);

void main() {
  MrtTrackBloc build(_FakeRepo repo, {List<String>? vibrated}) => MrtTrackBloc(
    i18n: zhStrings,
    repository: repo,
    liveActivityEnabled: () => false,
    vibrate: (id, event) async => vibrated?.add('$id:${event.name}'),
  );

  test('CreateTrack hands up the strings the server cannot derive', () async {
    final repo = _FakeRepo()..createResult = _session();
    final bloc = build(repo);
    addTearDown(bloc.close);

    bloc.add(
      const MrtTrackRequested(
        carId: '1163',
        boardStationId: 'BL12',
        destStationId: 'BL23',
        targetStationId: 'BL18',
        leadStops: 1,
      ),
    );
    await bloc.stream.firstWhere((s) => s.session != null);

    expect(repo.createdCards.single[1], 'BL');
    expect(repo.createdCards.single[0], isNotEmpty);
    expect(repo.createdCards.single[2], '#0070BD');
  });

  test('a push token reaches the server against the live session', () async {
    final repo = _FakeRepo()..createResult = _session();
    final bloc = build(repo);
    addTearDown(bloc.close);

    bloc.add(
      const MrtTrackRequested(
        carId: '1163',
        boardStationId: 'BL12',
        destStationId: 'BL23',
        targetStationId: 'BL18',
        leadStops: 1,
      ),
    );
    await bloc.stream.firstWhere((s) => s.session != null);

    bloc.add(const MrtTrackPushTokenReceived('deadbeef'));
    await Future<void>.delayed(Duration.zero);

    expect(repo.pushTokens, const [('t1', 'deadbeef')]);
  });

  test('a push token with no session behind it is dropped', () async {
    final repo = _FakeRepo();
    final bloc = build(repo);
    addTearDown(bloc.close);

    // iOS issues the token against the card, and a card with no session behind
    // it is already on its way out.
    bloc.add(const MrtTrackPushTokenReceived('deadbeef'));
    await Future<void>.delayed(Duration.zero);

    expect(repo.pushTokens, isEmpty);
  });

  test('a failed push token upload leaves the session running', () async {
    final repo = _FakeRepo()
      ..createResult = _session()
      ..pushTokenError = const GrpcError.unavailable('down');
    final bloc = build(repo);
    addTearDown(bloc.close);

    bloc.add(
      const MrtTrackRequested(
        carId: '1163',
        boardStationId: 'BL12',
        destStationId: 'BL23',
        targetStationId: 'BL18',
        leadStops: 1,
      ),
    );
    await bloc.stream.firstWhere((s) => s.session != null);

    bloc.add(const MrtTrackPushTokenReceived('deadbeef'));
    await Future<void>.delayed(Duration.zero);

    // The card simply degrades to local updates, which is what it did before
    // push existed. Tracking must not fall over because a refresh channel
    // could not be set up.
    expect(bloc.state.session, isNotNull);
  });

  test('CreateTrack success adopts the session and clears creating', () async {
    final repo = _FakeRepo()..createResult = _session();
    final bloc = build(repo);
    addTearDown(bloc.close);

    bloc.add(
      const MrtTrackRequested(
        carId: '1163',
        boardStationId: 'BL12',
        destStationId: 'BL23',
        targetStationId: 'BL18',
        leadStops: 1,
      ),
    );

    final state = await bloc.stream.firstWhere((s) => s.session != null);
    expect(state.creating, isFalse);
    expect(state.createError, MrtTrackCreateError.none);
    expect(state.session!.trackId, 't1');
    expect(state.isActive, isTrue);
  });

  test(
    'a watch frame advances the session, a terminal frame clears it',
    () async {
      final repo = _FakeRepo()..createResult = _session();
      final bloc = build(repo);
      addTearDown(bloc.close);

      bloc.add(
        const MrtTrackRequested(
          carId: '1163',
          boardStationId: 'BL12',
          destStationId: 'BL23',
          targetStationId: 'BL18',
          leadStops: 1,
        ),
      );
      await bloc.stream.firstWhere((s) => s.session != null);
      // The watch subscription is wired one microtask after the session emits;
      // let it attach before pushing frames onto the broadcast stream.
      await Future<void>.delayed(const Duration(milliseconds: 10));

      repo.controller.add(_session(currentIndex: 2, remainingStops: 1));
      final advanced = await bloc.stream.firstWhere(
        (s) => s.session?.currentIndex == 2,
      );
      expect(advanced.session!.remainingStops, 1);

      repo.controller.add(_session(status: MrtTrackStatus.arrived));
      final ended = await bloc.stream.firstWhere((s) => s.session == null);
      expect(ended.isActive, isFalse);
    },
  );

  test('each stops-remaining crossing fires its own vibration once', () async {
    final vibrated = <String>[];
    final repo = _FakeRepo()..createResult = _session();
    final bloc = build(repo, vibrated: vibrated);
    addTearDown(bloc.close);

    bloc.add(
      const MrtTrackRequested(
        carId: '1163',
        boardStationId: 'BL12',
        destStationId: 'BL23',
        targetStationId: 'BL18',
        leadStops: 1,
      ),
    );
    await bloc.stream.firstWhere((s) => s.session != null);
    await Future<void>.delayed(const Duration(milliseconds: 10));

    repo.controller.add(
      _session(
        currentIndex: 1,
        remainingStops: 2,
        status: MrtTrackStatus.leadFired,
      ),
    );
    await bloc.stream.firstWhere((s) => s.session?.remainingStops == 2);
    expect(vibrated, ['t1:lead']);

    // A repeat of the same reading is not a crossing and must stay silent.
    repo.controller.add(
      _session(
        currentIndex: 1,
        remainingStops: 2,
        status: MrtTrackStatus.leadFired,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(vibrated, ['t1:lead']);

    repo.controller.add(
      _session(
        currentIndex: 2,
        remainingStops: 1,
        status: MrtTrackStatus.leadFired,
      ),
    );
    await bloc.stream.firstWhere((s) => s.session?.remainingStops == 1);
    expect(vibrated, ['t1:lead', 't1:alight']);
  });

  test('InvalidArgument maps to notReachable, NotFound to notFound', () async {
    final repo = _FakeRepo()..createError = const GrpcError.invalidArgument();
    final bloc = build(repo);
    addTearDown(bloc.close);

    bloc.add(
      const MrtTrackRequested(
        carId: '1163',
        boardStationId: 'BL12',
        destStationId: 'BL23',
        targetStationId: 'BL01',
        leadStops: 1,
      ),
    );
    final rejected = await bloc.stream.firstWhere(
      (s) => s.createError != MrtTrackCreateError.none,
    );
    expect(rejected.createError, MrtTrackCreateError.notReachable);
    expect(rejected.session, isNull);

    repo.createError = const GrpcError.notFound();
    bloc.add(
      const MrtTrackRequested(
        carId: '9999',
        boardStationId: 'BL12',
        destStationId: 'BL23',
        targetStationId: 'BL18',
        leadStops: 1,
      ),
    );
    final notFound = await bloc.stream.firstWhere(
      (s) => s.createError == MrtTrackCreateError.notFound,
    );
    expect(notFound.session, isNull);
  });

  test(
    'a terminal frame shows the ending on the activity before dismissal',
    () async {
      final channel = _FakeChannel();
      final repo = _FakeRepo()..createResult = _session();
      final bloc = MrtTrackBloc(
        i18n: zhStrings,
        repository: repo,
        channel: channel,
        liveActivityEnabled: () => true,
        vibrate: (_, _) async {},
      );
      addTearDown(bloc.close);

      bloc.add(
        const MrtTrackRequested(
          carId: '1163',
          boardStationId: 'BL12',
          destStationId: 'BL23',
          targetStationId: 'BL18',
          leadStops: 1,
        ),
      );
      await bloc.stream.firstWhere((s) => s.session != null);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      repo.controller.add(_session(status: MrtTrackStatus.arrived));
      await bloc.stream.firstWhere((s) => s.session == null);
      await Future<void>.delayed(Duration.zero);

      expect(channel.updates.last.phase, AlightTrackPhase.arrived);
      expect(channel.stopped, isEmpty);
    },
  );

  test('rebinding releases the previous activity lease first', () async {
    final channel = _FakeChannel();
    final repo = _FakeRepo()..createResult = _session();
    final bloc = MrtTrackBloc(
      i18n: zhStrings,
      repository: repo,
      channel: channel,
      liveActivityEnabled: () => true,
      vibrate: (_, _) async {},
    );
    addTearDown(bloc.close);

    bloc.add(
      const MrtTrackRequested(
        carId: '1163',
        boardStationId: 'BL12',
        destStationId: 'BL23',
        targetStationId: 'BL18',
        leadStops: 1,
      ),
    );
    await bloc.stream.firstWhere((s) => s.session != null);

    repo.createResult = _session(trackId: 't2');
    bloc.add(
      const MrtTrackRequested(
        carId: '1165',
        boardStationId: 'BL12',
        destStationId: 'BL23',
        targetStationId: 'BL18',
        leadStops: 1,
      ),
    );
    await bloc.stream.firstWhere((s) => s.session?.trackId == 't2');

    // The first session's lease was stopped before the second one started —
    // no orphaned Live Activity left on screen.
    expect(channel.stopped, [1]);
    expect(channel.started, hasLength(2));
  });

  test('CancelTrack clears the session and calls the repository', () async {
    final repo = _FakeRepo()..createResult = _session();
    final bloc = build(repo);
    addTearDown(bloc.close);

    bloc.add(
      const MrtTrackRequested(
        carId: '1163',
        boardStationId: 'BL12',
        destStationId: 'BL23',
        targetStationId: 'BL18',
        leadStops: 1,
      ),
    );
    await bloc.stream.firstWhere((s) => s.session != null);

    bloc.add(const MrtTrackCancelled());
    final cancelled = await bloc.stream.firstWhere((s) => s.session == null);
    expect(cancelled.isActive, isFalse);
    // The cancel RPC fires best-effort after local teardown.
    await Future<void>.delayed(Duration.zero);
    expect(repo.cancelled, contains('t1'));
  });

  test(
    'a train still pulling in reads as waiting, then switches to riding',
    () async {
      final repo = _FakeRepo()..createResult = _session();
      final board = StreamController<int>.broadcast();
      final channel = _FakeChannel();
      final bloc = MrtTrackBloc(
        i18n: zhStrings,
        repository: repo,
        channel: channel,
        liveActivityEnabled: () => true,
        vibrate: (_, _) async {},
        boardEtaStream:
            ({
              required system,
              required stationId,
              required trainNumber,
            }) => board.stream,
      );
      addTearDown(bloc.close);

      bloc.add(
        const MrtTrackRequested(
          carId: '1163',
          boardStationId: 'BL12',
          destStationId: 'BL23',
          targetStationId: 'BL18',
          leadStops: 1,
          trainNumber: '215',
          // The rider armed it while the train was three minutes out.
          boardEtaSeconds: 180,
        ),
      );
      await bloc.stream.firstWhere((s) => s.session != null);
      await Future<void>.delayed(Duration.zero);

      // Opens on the reading the rider was just looking at, not on a claim
      // that they are already riding.
      expect(channel.started.single.phase, AlightTrackPhase.waiting);
      expect(channel.started.single.etaMinutes, 3);

      // Printed exactly as the feed reports it — nothing ticks in between.
      board.add(60);
      await Future<void>.delayed(Duration.zero);
      expect(channel.updates.last.phase, AlightTrackPhase.waiting);
      expect(channel.updates.last.etaMinutes, 1);

      // Train is in: from here the WatchTrack frames are the authority.
      board.add(0);
      await Future<void>.delayed(Duration.zero);
      expect(channel.updates.last.phase, isNot(AlightTrackPhase.waiting));
      expect(channel.updates.last.etaMinutes, isNull);

      await board.close();
    },
  );

  test('a watch failure does not end the ride while it can still recover '
      '(a tunnel is not an ending)', () async {
    final repo = _FakeRepo()..createResult = _session();
    final bloc = build(repo);
    addTearDown(bloc.close);

    bloc.add(
      const MrtTrackRequested(
        carId: '1163',
        boardStationId: 'BL12',
        destStationId: 'BL23',
        targetStationId: 'BL18',
        leadStops: 1,
      ),
    );
    await bloc.stream.firstWhere((s) => s.session != null);

    bloc
      ..add(const MrtTrackWatchFailed())
      ..add(const MrtTrackWatchRecovered());
    await Future<void>.delayed(Duration.zero);

    expect(bloc.state.session, isNotNull);
  });

  test(
    'a watch failure that never recovers ends the session as 追蹤失效',
    () async {
      final repo = _FakeRepo()..createResult = _session();
      final bloc = build(repo);
      addTearDown(bloc.close);

      bloc.add(
        const MrtTrackRequested(
          carId: '1163',
          boardStationId: 'BL12',
          destStationId: 'BL23',
          targetStationId: 'BL18',
          leadStops: 1,
        ),
      );
      await bloc.stream.firstWhere((s) => s.session != null);

      // Fired directly rather than waiting out the two-minute grace window.
      bloc.add(const MrtTrackWatchLost());
      await bloc.stream.firstWhere((s) => s.session == null);

      expect(bloc.state.session, isNull);
    },
  );
}

class _FakeChannel extends AlightTrackChannel {
  final started = <AlightTrackContent>[];
  final updates = <AlightTrackContent>[];
  final stopped = <int>[];
  int _lease = 0;

  @override
  Future<int> start(AlightTrackContent content) async {
    started.add(content);
    return ++_lease;
  }

  @override
  Future<void> update(int lease, AlightTrackContent content) async {
    updates.add(content);
  }

  @override
  Future<void> stop(int lease) async {
    stopped.add(lease);
  }
}

class _FakeRepo extends MrtTrackRepository {
  _FakeRepo();

  final controller = StreamController<MrtTrackSession>.broadcast();
  MrtTrackSession? createResult;
  Object? createError;
  final cancelled = <String>[];
  final createdCards = <List<String>>[];
  final pushTokens = <(String, String)>[];
  Object? pushTokenError;

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
    createdCards.add([vehicleLabel, lineCode, lineColorHex]);
    final err = createError;
    // The fake reproduces the supplied failure object.
    // ignore: only_throw_errors — mirrors the gRPC errors the seam surfaces.
    if (err != null) throw err;
    return createResult!;
  }

  @override
  Future<void> setPushToken(String trackId, String token) async {
    final err = pushTokenError;
    // The fake reproduces the supplied failure object.
    // ignore: only_throw_errors — mirrors the gRPC errors the seam surfaces.
    if (err != null) throw err;
    pushTokens.add((trackId, token));
  }

  @override
  Stream<MrtTrackSession> watch(String trackId) => controller.stream;

  @override
  Future<void> cancel(String trackId) async => cancelled.add(trackId);
}
