import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/core/live_activity/alight_track.dart';
import 'package:wheres_the_bus/data/models/bus_models.dart';
import 'package:wheres_the_bus/data/models/plan_models.dart';
import 'package:wheres_the_bus/data/tracking/journey_models.dart';
import 'package:wheres_the_bus/data/tracking/journey_session_bloc.dart';
import 'package:wheres_the_bus/data/tracking/journey_session_event.dart';
import 'package:wheres_the_bus/data/tracking/journey_session_state.dart';
import 'package:wheres_the_bus/data/tracking/tracking_session.dart';

/// Captures the last content pushed through the platform channel so tests
/// can assert on `_content()`'s output without the method channel firing.
class _CapturingChannel extends AlightTrackChannel {
  AlightTrackContent? last;
  int _lease = 0;

  @override
  Future<int> start(AlightTrackContent content) async {
    last = content;
    return ++_lease;
  }

  @override
  Future<void> update(int lease, AlightTrackContent content) async {
    last = content;
  }

  @override
  Future<void> stop(int lease) async {}
}

final _route = BusRouteViewModel(
  subRouteUid: 'sub-307',
  routeName: '307',
  subRouteName: '307',
  departureStopName: '第一站',
  destinationStopName: '終點',
  city: 'Taipei',
  headsignGo: '板橋',
  headsignReturn: '昆陽',
  stopsGo: [
    for (var seq = 1; seq <= 5; seq++)
      BusStopModel(
        stopUid: 'stop-$seq',
        stopName: ['第一站', '第二站', '第三站', '第四站', '終點'][seq - 1],
        sequence: seq,
        lat: 25,
        lon: 121.5,
      ),
  ],
);

bool _alwaysEnabled() => true;

JourneyLeg _leg() => const JourneyLeg(
  kind: JourneyLegKind.bus,
  routeLabel: '307 往板橋',
  boardStop: '捷運昆陽站',
  alightStop: '板橋',
  stopNames: [],
  identity: PlanIdentity(
    routeType: 'bus',
    routeKey: 'sub-307',
    direction: '0',
    departureStopKey: 'stop-1',
    arrivalStopKey: '',
    supported: false,
  ),
  leadingWalkMinutes: 0,
  scheduledDeparture: null,
  scheduledArrival: null,
  boardLocation: PlanPoint(lat: 25, lng: 121.5),
  stopLocations: [],
);

void main() {
  late StreamController<Duration?> etaCtrl;
  late StreamController<List<BusStopEtaViewModel>> routeEtaCtrl;
  JourneySessionBloc bloc({
    Duration linger = const Duration(minutes: 2),
    AlightTrackChannel? channel,
    // Defaults on so the many tests unrelated to this setting don't touch
    // SettingsRepository (and, through it, an unopened Hive box).
    bool Function() liveActivityEnabled = _alwaysEnabled,
  }) => JourneySessionBloc(
    etaStream: (_) => etaCtrl.stream,
    routeEtaStream: (_) => routeEtaCtrl.stream,
    trackOnlyLinger: linger,
    channel: channel,
    liveActivityEnabled: liveActivityEnabled,
    // The real haptics reach a platform channel these tests have no binding
    // for; the crossing logic they would exercise is covered on its own.
    vibrate: (_, _) async {},
  );

  setUp(() {
    etaCtrl = StreamController<Duration?>.broadcast();
    routeEtaCtrl = StreamController<List<BusStopEtaViewModel>>.broadcast();
  });
  tearDown(() => Future.wait([etaCtrl.close(), routeEtaCtrl.close()]));

  test('trackOnly session waits without suggesting boarding at zero', () async {
    final b = bloc()..add(JourneyStarted(legs: [_leg()], trackOnly: true));
    final started = await b.stream.firstWhere(
      (s) => s.phase == JourneyPhase.waiting,
    );
    expect(started.trackOnly, isTrue);
    etaCtrl.add(Duration.zero);
    final s = await b.stream.firstWhere((s) => s.eta == Duration.zero);
    expect(s.suggestBoarding, isFalse);
    expect(s.phase, JourneyPhase.waiting);
    await b.close();
  });

  test('trackOnly ignores board confirmations', () async {
    final b = bloc()..add(JourneyStarted(legs: [_leg()], trackOnly: true));
    await b.stream.firstWhere((s) => s.phase == JourneyPhase.waiting);
    b
      ..add(const BoardConfirmed())
      ..add(const JourneyCancelled());
    final s = await b.stream.firstWhere((s) => s.phase == JourneyPhase.done);
    expect(s.trackOnly, isTrue);
    await b.close();
  });

  test('eta jumping back up after arrival ends a trackOnly session', () async {
    final b = bloc()..add(JourneyStarted(legs: [_leg()], trackOnly: true));
    await b.stream.firstWhere((s) => s.phase == JourneyPhase.waiting);
    etaCtrl.add(Duration.zero);
    await b.stream.firstWhere((s) => s.eta == Duration.zero);
    // The stream now counts down the following bus.
    etaCtrl.add(const Duration(minutes: 9));
    await b.stream.firstWhere((s) => s.phase == JourneyPhase.done);
    await b.close();
  });

  test('trackOnly session lingers then ends after arrival', () async {
    final b = bloc(linger: const Duration(milliseconds: 50))
      ..add(JourneyStarted(legs: [_leg()], trackOnly: true));
    await b.stream.firstWhere((s) => s.phase == JourneyPhase.waiting);
    etaCtrl.add(Duration.zero);
    await b.stream.firstWhere((s) => s.phase == JourneyPhase.done);
    await b.close();
  });

  test('navigation sessions still suggest boarding at zero', () async {
    final b = bloc()..add(JourneyStarted(legs: [_leg()]));
    await b.stream.firstWhere((s) => s.phase == JourneyPhase.waiting);
    etaCtrl.add(Duration.zero);
    final s = await b.stream.firstWhere((s) => s.eta == Duration.zero);
    expect(s.suggestBoarding, isTrue);
    expect(s.trackOnly, isFalse);
    await b.close();
  });

  test('trackOnly session carries a plate', () async {
    final b = bloc()
      ..add(
        JourneyStarted(legs: [_leg()], trackOnly: true, plate: 'KKA-1288'),
      );
    final s = await b.stream.firstWhere(
      (s) => s.phase == JourneyPhase.waiting,
    );
    expect(s.plate, 'KKA-1288');
    await b.close();
  });

  test('JourneyStarted without a plate leaves state.plate null', () async {
    final b = bloc()..add(JourneyStarted(legs: [_leg()], trackOnly: true));
    final s = await b.stream.firstWhere(
      (s) => s.phase == JourneyPhase.waiting,
    );
    expect(s.plate, isNull);
    await b.close();
  });

  test(
    'pinned session tracks the plate by estimate, not the route-wide fleet',
    () async {
      final channel = _CapturingChannel();
      final b = bloc(channel: channel)
        ..add(
          JourneyStarted(legs: [_leg()], trackOnly: true, plate: 'KKA-1288'),
        );
      await b.stream.firstWhere((s) => s.phase == JourneyPhase.waiting);
      expect(routeEtaCtrl.hasListener, isTrue);

      // The backend puts the whole route's fleet on EVERY stop, so `vehicles`
      // cannot locate the bus. Only `plate` — the vehicle this estimate is
      // about — can.
      const fleet = [
        BusVehiclePosition(plate: 'KKA-1288', lat: 25, lon: 121.5, azimuth: 0),
        BusVehiclePosition(plate: 'ZZZ-0001', lat: 25, lon: 121.6, azimuth: 0),
      ];

      List<BusStopEtaViewModel> frame({required int plateAtSequence}) => [
        for (var seq = 5; seq <= 10; seq++)
          BusStopEtaViewModel(
            stopUid: seq == 10 ? 'stop-1' : 'stop-$seq',
            direction: 0,
            sequence: seq,
            estimateSeconds: 0,
            nextBusTime: '',
            stopStatus: 0,
            vehiclePlates: const ['KKA-1288', 'ZZZ-0001'],
            vehicles: fleet,
            plate: seq == plateAtSequence ? 'KKA-1288' : 'ZZZ-0001',
          ),
      ];

      // Target stop 'stop-1' is at sequence 10; our bus is next due at
      // sequence 7 → 3 stops remaining.
      routeEtaCtrl.add(frame(plateAtSequence: 7));
      final first = await b.stream.firstWhere(
        (s) => s.pinnedStopsRemaining != null,
      );
      expect(first.pinnedStopsRemaining, 3);
      expect(channel.last?.remainingStops, 3);
      expect(channel.last?.vehicleId, 'KKA-1288');
      expect(channel.last?.vehicleLabel, '307');

      // The bus advances two stops — the count MUST decrease. This is the
      // regression guard for the constant-count bug.
      routeEtaCtrl.add(frame(plateAtSequence: 9));
      final second = await b.stream.firstWhere(
        (s) => s.pinnedStopsRemaining == 1,
      );
      expect(second.pinnedStopsRemaining, 1);

      await b.close();
    },
  );

  test('a pinned bus card names the picked stop and walks its bar', () async {
    final channel = _CapturingChannel();
    final b = bloc(channel: channel)
      ..add(
        JourneyStarted(
          legs: [
            busTrackingLeg(
              route: _route,
              stops: _route.stopsGo,
              boardIndex: 0,
              targetIndex: 3,
              direction: 0,
            ),
          ],
          trackOnly: true,
          plate: 'KKA-1288',
        ),
      );
    await b.stream.firstWhere((s) => s.phase == JourneyPhase.waiting);

    List<BusStopEtaViewModel> frame(int plateAtSequence) => [
      for (var seq = 1; seq <= 4; seq++)
        BusStopEtaViewModel(
          stopUid: 'stop-$seq',
          direction: 0,
          sequence: seq,
          estimateSeconds: 0,
          nextBusTime: '',
          stopStatus: 0,
          vehiclePlates: const ['KKA-1288'],
          plate: seq == plateAtSequence ? 'KKA-1288' : '',
        ),
    ];

    // The rider picked stop-4, which is not the route's terminus.
    routeEtaCtrl.add(frame(2));
    await b.stream.firstWhere((s) => s.pinnedStopsRemaining == 2);
    expect(channel.last?.targetStation, '第四站');
    expect(channel.last?.hopCount, 3);
    expect(channel.last?.currentIndex, 1);
    expect(channel.last?.nextStation, '第三站');

    // One stop on: the bar walks, the denominator does not move.
    routeEtaCtrl.add(frame(3));
    await b.stream.firstWhere((s) => s.pinnedStopsRemaining == 1);
    expect(channel.last?.hopCount, 3);
    expect(channel.last?.currentIndex, 2);
    expect(channel.last?.nextStation, '第四站');

    await b.close();
  });

  test(
    'the buzz is filed under the card session, not a process counter',
    () async {
      final channel = _CapturingChannel();
      final fired = <String>[];
      final b =
          JourneySessionBloc(
            etaStream: (_) => etaCtrl.stream,
            routeEtaStream: (_) => routeEtaCtrl.stream,
            channel: channel,
            liveActivityEnabled: _alwaysEnabled,
            vibrate: (id, _) async => fired.add(id),
          )..add(
            JourneyStarted(
              legs: [
                busTrackingLeg(
                  route: _route,
                  stops: _route.stopsGo,
                  boardIndex: 0,
                  targetIndex: 3,
                  direction: 0,
                ),
              ],
              trackOnly: true,
              plate: 'KKA-1288',
            ),
          );
      await b.stream.firstWhere((s) => s.phase == JourneyPhase.waiting);

      List<BusStopEtaViewModel> frame(int plateAtSequence) => [
        for (var seq = 1; seq <= 4; seq++)
          BusStopEtaViewModel(
            stopUid: 'stop-$seq',
            direction: 0,
            sequence: seq,
            estimateSeconds: 0,
            nextBusTime: '',
            stopStatus: 0,
            vehiclePlates: const ['KKA-1288'],
            plate: seq == plateAtSequence ? 'KKA-1288' : '',
          ),
      ];

      routeEtaCtrl.add(frame(2));
      await b.stream.firstWhere((s) => s.pinnedStopsRemaining == 2);
      // 還剩 1 站: 下車站 is next, which is the long buzz.
      routeEtaCtrl.add(frame(3));
      await b.stream.firstWhere((s) => s.pinnedStopsRemaining == 1);

      expect(fired, [channel.last!.trackId]);
      await b.close();
    },
  );

  test(
    'pinned stops-remaining matches plates that differ only by case/whitespace',
    () async {
      final b = bloc()
        ..add(
          JourneyStarted(
            legs: [_leg()],
            trackOnly: true,
            plate: ' kka-1288 ',
          ),
        );
      await b.stream.firstWhere((s) => s.phase == JourneyPhase.waiting);

      // The estimate's plate is server-normalized (trimmed + upper-cased);
      // the tracked plate above is raw, as the position feed sends it.
      List<BusStopEtaViewModel> frame({required int plateAtSequence}) => [
        for (var seq = 5; seq <= 10; seq++)
          BusStopEtaViewModel(
            stopUid: seq == 10 ? 'stop-1' : 'stop-$seq',
            direction: 0,
            sequence: seq,
            estimateSeconds: 0,
            nextBusTime: '',
            stopStatus: 0,
            vehiclePlates: const ['KKA-1288', 'ZZZ-0001'],
            plate: seq == plateAtSequence ? 'KKA-1288' : 'ZZZ-0001',
          ),
      ];

      // Target stop 'stop-1' is at sequence 10; our bus is next due at
      // sequence 7 → 3 stops remaining.
      routeEtaCtrl.add(frame(plateAtSequence: 7));
      final first = await b.stream.firstWhere(
        (s) => s.pinnedStopsRemaining != null,
      );
      expect(first.pinnedStopsRemaining, 3);

      await b.close();
    },
  );

  test(
    'pinned stops-remaining holds last-known when a frame cannot resolve '
    'the plate',
    () async {
      final b = bloc()
        ..add(
          JourneyStarted(legs: [_leg()], trackOnly: true, plate: 'KKA-1288'),
        );
      await b.stream.firstWhere((s) => s.phase == JourneyPhase.waiting);

      BusStopEtaViewModel target(int sequence) => BusStopEtaViewModel(
        stopUid: 'stop-1',
        direction: 0,
        sequence: sequence,
        estimateSeconds: 0,
        nextBusTime: '',
        stopStatus: 0,
        vehiclePlates: const [],
      );
      BusStopEtaViewModel plateAt(int sequence) => BusStopEtaViewModel(
        stopUid: 'stop-0',
        direction: 0,
        sequence: sequence,
        estimateSeconds: 0,
        nextBusTime: '',
        stopStatus: 0,
        vehiclePlates: const ['KKA-1288'],
        plate: 'KKA-1288',
      );

      // Frame 1: the pinned plate sits 3 stops before the target.
      routeEtaCtrl.add([target(10), plateAt(7)]);
      final s1 = await b.stream.firstWhere(
        (s) => s.pinnedStopsRemaining != null,
      );
      expect(s1.pinnedStopsRemaining, 3);

      // Frame 2: the plate is absent from every stop's `plate` field this
      // frame (momentarily between stops) — the last-known value holds.
      routeEtaCtrl.add([target(10)]);
      await Future<void>.delayed(Duration.zero);
      expect(b.state.pinnedStopsRemaining, 3);

      // Frame 3: the plate resolves again, now 2 stops out.
      routeEtaCtrl.add([target(10), plateAt(8)]);
      final s3 = await b.stream.firstWhere(
        (s) => s.pinnedStopsRemaining == 2,
      );
      expect(s3.pinnedStopsRemaining, 2);

      await b.close();
    },
  );

  test('unpinned waiting session never subscribes to route ETA', () async {
    final channel = _CapturingChannel();
    final b = bloc(channel: channel)..add(JourneyStarted(legs: [_leg()]));
    await b.stream.firstWhere((s) => s.phase == JourneyPhase.waiting);
    await Future<void>.delayed(Duration.zero);
    expect(routeEtaCtrl.hasListener, isFalse);
    expect(b.state.pinnedStopsRemaining, isNull);
    expect(channel.last?.vehicleId, isNull);
    expect(channel.last?.vehicleLabel, '307');
    // Nothing is being followed, so the card counts minutes to the board
    // stop rather than stops to an alight stop.
    expect(channel.last?.phase, AlightTrackPhase.waiting);
    await b.close();
  });

  test('no Live Activity is started when the setting is off', () async {
    final channel = _CapturingChannel();
    final b = bloc(channel: channel, liveActivityEnabled: () => false)
      ..add(JourneyStarted(legs: [_leg()], trackOnly: true, plate: 'KKA-1288'));

    // Give the bloc a turn of the event loop to process the event.
    await Future<void>.delayed(Duration.zero);

    expect(b.state.phase, JourneyPhase.idle);
    expect(channel.last, isNull);
    expect(routeEtaCtrl.hasListener, isFalse);

    await b.close();
  });
}
