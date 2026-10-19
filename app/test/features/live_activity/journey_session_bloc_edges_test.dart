import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:wheres_the_bus/core/live_activity/alight_track.dart';
import 'package:wheres_the_bus/data/models/bus_models.dart';
import 'package:wheres_the_bus/data/models/plan_models.dart';
import 'package:wheres_the_bus/data/tracking/journey_models.dart';
import 'package:wheres_the_bus/data/tracking/journey_session_bloc.dart';
import 'package:wheres_the_bus/data/tracking/journey_session_event.dart';
import 'package:wheres_the_bus/data/tracking/journey_session_state.dart';
import 'package:wheres_the_bus/data/tracking/leg_eta_source.dart';

class _Channel extends AlightTrackChannel {
  final updates = <AlightTrackContent>[];
  final stopped = <int>[];
  int stopAnyCalls = 0;
  Completer<void>? startGate;
  int _lease = 0;

  @override
  Future<int> start(AlightTrackContent content) async {
    final gate = startGate;
    if (gate != null) await gate.future;
    return ++_lease;
  }

  @override
  Future<void> update(int lease, AlightTrackContent content) async =>
      updates.add(content);

  @override
  Future<void> stop(int lease) async => stopped.add(lease);

  @override
  Future<void> stopAny() async => stopAnyCalls++;
}

const _stops = [
  PlanPoint(lat: 25.01, lng: 121.51),
  PlanPoint(lat: 25.02, lng: 121.52),
  PlanPoint(lat: 25.03, lng: 121.53),
  PlanPoint(lat: 25.04, lng: 121.54),
];

JourneyLeg _busLeg() => JourneyLeg(
  kind: JourneyLegKind.bus,
  routeLabel: '307 往板橋',
  boardStop: '起點站',
  alightStop: '終點站',
  stopNames: const ['甲', '乙', '丙'],
  identity: const PlanIdentity(
    routeType: 'bus',
    routeKey: 'R307',
    direction: '',
    departureStopKey: 'TARGET',
    arrivalStopKey: '',
    supported: true,
  ),
  leadingWalkMinutes: 0,
  scheduledDeparture: DateTime(2026, 7, 6, 10),
  scheduledArrival: DateTime(2026, 7, 6, 10, 30),
  boardLocation: const PlanPoint(lat: 25, lng: 121.5),
  stopLocations: _stops,
);

JourneyLeg _railLeg() => JourneyLeg(
  kind: JourneyLegKind.tra,
  routeLabel: '自強 123 往台中',
  boardStop: '台北',
  alightStop: '台中',
  stopNames: const [],
  identity: const PlanIdentity(
    routeType: 'tra',
    routeKey: '123',
    direction: '2026-07-20',
    departureStopKey: '',
    arrivalStopKey: '',
    supported: false,
  ),
  leadingWalkMinutes: 0,
  scheduledDeparture: null,
  scheduledArrival: null,
  boardLocation: const PlanPoint(lat: 0, lng: 0),
  stopLocations: const [],
  railSchedule: [
    RailStopSchedule(name: '台北', scheduledArrival: DateTime(2026, 7, 20, 8)),
    RailStopSchedule(name: '台中', scheduledArrival: DateTime(2026, 7, 20, 9)),
  ],
);

RailTrackFrame _frame(Duration eta) => (
  remainingStops: 1,
  etaToAlight: eta,
  progress: 0.5,
  nextStop: '台中',
  aboard: true,
  etaToBoard: Duration.zero,
  delay: Duration.zero,
);

BusStopEtaViewModel _eta(String stop, int sequence, {String plate = ''}) =>
    BusStopEtaViewModel(
      stopUid: stop,
      direction: 0,
      sequence: sequence,
      estimateSeconds: 60,
      nextBusTime: '',
      stopStatus: 0,
      vehiclePlates: const [],
      plate: plate,
    );

void main() {
  late List<StreamController<Duration?>> etas;
  late List<StreamController<List<BusStopEtaViewModel>>> routes;
  late List<StreamController<RailTrackFrame>> rails;
  late List<StreamController<Position>> positions;
  late _Channel channel;

  setUp(() {
    etas = [];
    routes = [];
    rails = [];
    positions = [];
    channel = _Channel();
  });

  tearDown(() async {
    for (final c in [...etas, ...routes, ...rails, ...positions]) {
      await c.close();
    }
  });

  JourneySessionBloc build({
    Duration linger = const Duration(milliseconds: 80),
    bool withPositions = true,
    bool withChannel = true,
  }) {
    final bloc = JourneySessionBloc(
      etaStream: (_) {
        final c = StreamController<Duration?>.broadcast();
        etas.add(c);
        return c.stream;
      },
      routeEtaStream: (_) {
        final c = StreamController<List<BusStopEtaViewModel>>.broadcast();
        routes.add(c);
        return c.stream;
      },
      railTrackStream: (_) {
        final c = StreamController<RailTrackFrame>.broadcast();
        rails.add(c);
        return c.stream;
      },
      positions: withPositions
          ? () {
              final c = StreamController<Position>.broadcast();
              positions.add(c);
              return c.stream;
            }
          : null,
      channel: withChannel ? channel : null,
      liveActivityEnabled: () => true,
      vibrate: (_, _) async {},
      trackOnlyLinger: linger,
    );
    addTearDown(bloc.close);
    return bloc;
  }

  Future<JourneySessionBloc> started(
    JourneyStarted event, {
    Duration linger = const Duration(milliseconds: 80),
    bool withPositions = true,
  }) async {
    final bloc = build(linger: linger, withPositions: withPositions)
      ..add(event);
    await bloc.stream.firstWhere((s) => s.phase == JourneyPhase.waiting);
    await pumpEventQueue();
    return bloc;
  }

  Future<void> real([int ms = 250]) =>
      Future<void>.delayed(Duration(milliseconds: ms));

  group('arrival', () {
    test('a negative ETA still counts as arrived', () async {
      final bloc = await started(JourneyStarted(legs: [_busLeg()]));
      etas.single.add(const Duration(seconds: -5));
      final s = await bloc.stream.firstWhere((s) => s.eta != null);
      expect(s.suggestBoarding, isTrue);
    });

    test('a tracked ride does not end before the bus has arrived', () async {
      final bloc = await started(
        JourneyStarted(legs: [_busLeg()], trackOnly: true),
      );
      etas.single.add(const Duration(minutes: 5));
      await real();
      expect(bloc.state.phase, JourneyPhase.waiting);
      etas.single.add(const Duration(minutes: 4));
      await real();
      expect(bloc.state.phase, JourneyPhase.waiting);
    });

    test('a tracked ride ends a moment after the bus arrives', () async {
      final bloc = await started(
        JourneyStarted(legs: [_busLeg()], trackOnly: true),
      );
      etas.single.add(Duration.zero);
      await bloc.stream.firstWhere((s) => s.phase == JourneyPhase.done);
    });

    test('a later ETA over a minute means the bus has left', () async {
      final bloc = await started(
        JourneyStarted(legs: [_busLeg()], trackOnly: true),
        linger: const Duration(minutes: 5),
      );
      etas.single.add(Duration.zero);
      await pumpEventQueue();
      etas.single.add(const Duration(minutes: 1));
      await real(100);
      expect(bloc.state.phase, JourneyPhase.waiting);
      etas.single.add(const Duration(minutes: 2));
      await bloc.stream.firstWhere((s) => s.phase == JourneyPhase.done);
    });

    test(
      'a rail run ends after arrival, whether eta is zero or past',
      () async {
        for (final eta in [Duration.zero, const Duration(seconds: -30)]) {
          final bloc = await started(
            JourneyStarted(legs: [_railLeg()], trackOnly: true),
          );
          rails.last.add(_frame(eta));
          await bloc.stream.firstWhere((s) => s.phase == JourneyPhase.done);
        }
      },
    );

    test('a rail run mid-way is left running', () async {
      final bloc = await started(
        JourneyStarted(legs: [_railLeg()], trackOnly: true),
      );
      rails.single.add(_frame(const Duration(minutes: 20)));
      await real();
      expect(bloc.state.phase, JourneyPhase.waiting);
    });
  });

  group('guards', () {
    test('boarding twice or a tracked boarding changes nothing', () async {
      final bloc = await started(JourneyStarted(legs: [_busLeg()]));
      bloc.add(const BoardConfirmed());
      await bloc.stream.firstWhere((s) => s.phase == JourneyPhase.riding);
      await pumpEventQueue();
      final before = channel.updates.length;
      bloc.add(const BoardConfirmed());
      await pumpEventQueue();
      expect(channel.updates.length, before);

      final tracked = await started(
        JourneyStarted(legs: [_busLeg()], trackOnly: true),
      );
      tracked.add(const BoardConfirmed());
      await pumpEventQueue();
      expect(tracked.state.phase, JourneyPhase.waiting);
    });

    test('alighting before boarding changes nothing', () async {
      final bloc = await started(JourneyStarted(legs: [_busLeg()]));
      bloc.add(const AlightConfirmed());
      await pumpEventQueue();
      expect(bloc.state.phase, JourneyPhase.waiting);
    });

    test('progress only moves forward', () async {
      final bloc = await started(JourneyStarted(legs: [_busLeg()]));
      bloc.add(const BoardConfirmed());
      await bloc.stream.firstWhere((s) => s.phase == JourneyPhase.riding);
      await pumpEventQueue();
      final before = channel.updates.length;
      bloc.add(const ProgressTicked(0, generation: 1));
      await pumpEventQueue();
      expect(channel.updates.length, before);
      expect(bloc.state.nextStopIndex, 0);
      bloc.add(const ProgressTicked(2, generation: 1));
      await pumpEventQueue();
      expect(bloc.state.nextStopIndex, 2);
      bloc.add(const ProgressTicked(2, generation: 1));
      await pumpEventQueue();
      expect(channel.updates.length, before + 1);
    });

    test('riding without a position source still works', () async {
      final bloc = await started(
        JourneyStarted(legs: [_busLeg()]),
        withPositions: false,
      );
      bloc.add(const BoardConfirmed());
      await bloc.stream.firstWhere((s) => s.phase == JourneyPhase.riding);
      expect(positions, isEmpty);
    });
  });

  group('subscriptions', () {
    test('cancelling stops every feed', () async {
      final bloc = await started(
        JourneyStarted(legs: [_busLeg()], trackOnly: true, plate: 'ABC'),
      );
      expect(etas.single.hasListener, isTrue);
      expect(routes.single.hasListener, isTrue);
      bloc.add(const JourneyCancelled());
      await bloc.stream.firstWhere((s) => s.phase == JourneyPhase.done);
      await pumpEventQueue();
      expect(etas.single.hasListener, isFalse);
      expect(routes.single.hasListener, isFalse);
    });

    test('cancelling a rail run stops its feed', () async {
      final bloc = await started(
        JourneyStarted(legs: [_railLeg()], trackOnly: true),
      );
      expect(rails.single.hasListener, isTrue);
      bloc.add(const JourneyCancelled());
      await bloc.stream.firstWhere((s) => s.phase == JourneyPhase.done);
      await pumpEventQueue();
      expect(rails.single.hasListener, isFalse);
    });

    test(
      'boarding drops the ETA feed, alighting drops the position feed',
      () async {
        final bloc = await started(JourneyStarted(legs: [_busLeg()]));
        expect(etas.single.hasListener, isTrue);
        bloc.add(const BoardConfirmed());
        await bloc.stream.firstWhere((s) => s.phase == JourneyPhase.riding);
        await pumpEventQueue();
        expect(etas.single.hasListener, isFalse);
        expect(positions.single.hasListener, isTrue);
        bloc.add(const AlightConfirmed());
        await bloc.stream.firstWhere((s) => s.phase == JourneyPhase.done);
        await pumpEventQueue();
        expect(positions.single.hasListener, isFalse);
      },
    );

    test('alighting mid-journey drops the position feed too', () async {
      final bloc = await started(
        JourneyStarted(legs: [_busLeg(), _busLeg()]),
      );
      bloc.add(const BoardConfirmed());
      await bloc.stream.firstWhere((s) => s.phase == JourneyPhase.riding);
      await pumpEventQueue();
      bloc.add(const AlightConfirmed());
      await bloc.stream.firstWhere((s) => s.legIndex == 1);
      await pumpEventQueue();
      expect(positions.single.hasListener, isFalse);
      expect(etas, hasLength(2));
    });

    test('starting again replaces the previous feeds', () async {
      final bloc = await started(
        JourneyStarted(legs: [_busLeg()], trackOnly: true, plate: 'ABC'),
      );
      bloc.add(
        JourneyStarted(legs: [_busLeg()], trackOnly: true, plate: 'ABC'),
      );
      await pumpEventQueue();
      expect(etas, hasLength(2));
      expect(etas.first.hasListener, isFalse);
      expect(routes, hasLength(2));
      expect(routes.first.hasListener, isFalse);

      final rail = await started(
        JourneyStarted(legs: [_railLeg()], trackOnly: true),
      );
      rail.add(JourneyStarted(legs: [_railLeg()], trackOnly: true));
      await pumpEventQueue();
      expect(rails, hasLength(2));
      expect(rails.first.hasListener, isFalse);
    });

    test('closing releases every feed', () async {
      final bloc = await started(
        JourneyStarted(legs: [_busLeg()], trackOnly: true, plate: 'ABC'),
      );
      await bloc.close();
      await pumpEventQueue();
      expect(etas.single.hasListener, isFalse);
      expect(routes.single.hasListener, isFalse);

      final rail = await started(
        JourneyStarted(legs: [_railLeg()], trackOnly: true),
      );
      await rail.close();
      await pumpEventQueue();
      expect(rails.single.hasListener, isFalse);

      final riding = await started(JourneyStarted(legs: [_busLeg()]));
      riding.add(const BoardConfirmed());
      await riding.stream.firstWhere((s) => s.phase == JourneyPhase.riding);
      await pumpEventQueue();
      await riding.close();
      await pumpEventQueue();
      expect(positions.single.hasListener, isFalse);
    });
  });

  group('card lease', () {
    test('ending releases the lease it holds', () async {
      final bloc = await started(JourneyStarted(legs: [_busLeg()]));
      bloc.add(const JourneyCancelled(userInitiated: true));
      await bloc.stream.firstWhere((s) => s.phase == JourneyPhase.done);
      await pumpEventQueue();
      expect(channel.stopped, [1]);
      expect(channel.stopAnyCalls, 0);
    });

    test('a rider cancelling before the card exists clears any card', () async {
      channel.startGate = Completer<void>();
      final bloc = build()..add(JourneyStarted(legs: [_busLeg()]));
      await bloc.stream.firstWhere((s) => s.phase == JourneyPhase.waiting);
      bloc.add(const JourneyCancelled(userInitiated: true));
      await bloc.stream.firstWhere((s) => s.phase == JourneyPhase.done);
      await pumpEventQueue();
      expect(channel.stopAnyCalls, 1);
      channel.startGate!.complete();
      await pumpEventQueue();
      expect(channel.stopped, [1]);
    });

    test(
      'a system cancel before the card exists is not a rider clear',
      () async {
        channel.startGate = Completer<void>();
        final bloc = build()..add(JourneyStarted(legs: [_busLeg()]));
        await bloc.stream.firstWhere((s) => s.phase == JourneyPhase.waiting);
        bloc.add(const JourneyCancelled());
        await bloc.stream.firstWhere((s) => s.phase == JourneyPhase.done);
        await pumpEventQueue();
        expect(channel.stopAnyCalls, 0);
        channel.startGate!.complete();
        await pumpEventQueue();
      },
    );
  });

  group('card content', () {
    AlightTrackContent last() => channel.updates.last;

    Future<JourneySessionBloc> riding() async {
      final bloc = await started(JourneyStarted(legs: [_busLeg()]));
      bloc.add(const BoardConfirmed());
      await bloc.stream.firstWhere((s) => s.phase == JourneyPhase.riding);
      await pumpEventQueue();
      return bloc;
    }

    Future<void> moveTo(JourneySessionBloc bloc, int index) async {
      bloc.add(ProgressTicked(index, generation: 1));
      await pumpEventQueue();
    }

    test('stops remaining count down from the stop list', () async {
      final bloc = await riding();
      expect(last().remainingStops, 4);
      await moveTo(bloc, 1);
      expect(last().remainingStops, 3);
      await moveTo(bloc, 3);
      expect(last().remainingStops, 1);
    });

    test('the card warms up at the lead-plus-one boundary', () async {
      final bloc = await riding();
      expect(last().phase, AlightTrackPhase.riding);
      await moveTo(bloc, 1);
      expect(last().phase, AlightTrackPhase.riding);
      await moveTo(bloc, 2);
      expect(last().remainingStops, 2);
      expect(last().phase, AlightTrackPhase.approaching);
      await moveTo(bloc, 3);
      expect(last().phase, AlightTrackPhase.approaching);
    });

    test('a pinned bus already past the stop leaves zero stops', () async {
      final bloc = await started(
        JourneyStarted(legs: [_busLeg()], trackOnly: true, plate: 'ABC'),
      );
      routes.single.add([_eta('TARGET', 5), _eta('LATER', 9, plate: 'ABC')]);
      await pumpEventQueue();
      expect(bloc.state.pinnedStopsRemaining, 0);
      routes.single.add([_eta('TARGET', 9), _eta('EARLIER', 5, plate: 'ABC')]);
      await pumpEventQueue();
      expect(bloc.state.pinnedStopsRemaining, 4);
    });
  });
}
