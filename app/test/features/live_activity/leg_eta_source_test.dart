import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/models/bus_models.dart';
import 'package:wheres_the_bus/data/models/plan_models.dart';
import 'package:wheres_the_bus/data/repositories/bus_repository.dart';
import 'package:wheres_the_bus/data/repositories/tra_repository.dart';
import 'package:wheres_the_bus/data/tracking/journey_models.dart';
import 'package:wheres_the_bus/data/tracking/leg_eta_source.dart';

class _Bus extends BusRepository {
  List<BusStopArrival> arrivals = [];
  List<BusStopEtaViewModel> etas = [];
  String? station;
  String? route;

  @override
  Stream<List<BusStopArrival>> stationEta(String city, String groupUid) {
    expect(city, '');
    station = groupUid;
    return Stream.value(arrivals);
  }

  @override
  Stream<List<BusStopEtaViewModel>> routeEta(String subRouteUid) {
    route = subRouteUid;
    return Stream.value(etas);
  }
}

class _Tra extends TraRepository {
  final frames = StreamController<Map<String, int>>();
  List<String>? segment;

  @override
  Stream<Map<String, int>> delay(String date, String originId, String destId) {
    segment = [date, originId, destId];
    return frames.stream;
  }
}

JourneyLeg _leg({
  JourneyLegKind kind = JourneyLegKind.bus,
  bool supported = false,
  String route = 'R',
  String stop = 'S',
  String direction = '0',
  DateTime? departure,
}) => JourneyLeg(
  kind: kind,
  routeLabel: '307 往終點',
  boardStop: 'A',
  alightStop: 'B',
  stopNames: const [],
  identity: PlanIdentity(
    routeType: 'bus',
    routeKey: route,
    direction: direction,
    departureStopKey: stop,
    arrivalStopKey: '',
    supported: supported,
  ),
  leadingWalkMinutes: 0,
  scheduledDeparture: departure,
  scheduledArrival: null,
  boardLocation: const PlanPoint(lat: 0, lng: 0),
  stopLocations: const [],
);

BusStopArrival _arrival(String name, int seconds, {int status = 0}) =>
    BusStopArrival(
      stationId: 'S',
      subRouteUid: 'R',
      routeName: name,
      destination: '',
      estimateSeconds: seconds,
      stopStatus: status,
    );
BusStopEtaViewModel _eta({
  String stop = 'S',
  int direction = 0,
  int seconds = 0,
  int status = 0,
}) => BusStopEtaViewModel(
  stopUid: stop,
  direction: direction,
  sequence: 1,
  estimateSeconds: seconds,
  nextBusTime: '',
  stopStatus: status,
  vehiclePlates: const [],
);

void main() {
  test(
    'TRA tracking filters this train and retains its last delay on errors',
    () async {
      final now = DateTime(2026, 7, 20, 8, 30);
      final repository = _Tra();
      final leg = JourneyLeg(
        kind: JourneyLegKind.tra,
        routeLabel: '123',
        boardStop: 'A',
        alightStop: 'B',
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
          RailStopSchedule(
            name: 'A',
            scheduledArrival: DateTime(2026, 7, 20, 8),
          ),
          RailStopSchedule(
            name: 'B',
            scheduledArrival: DateTime(2026, 7, 20, 9),
          ),
        ],
      );
      final frames = <RailTrackFrame>[];
      final subscription = defaultRailTrackStream(
        leg,
        repository: repository,
        now: () => now,
        tick: const Duration(milliseconds: 10),
      ).listen(frames.add);
      addTearDown(subscription.cancel);
      addTearDown(repository.frames.close);
      await Future<void>.delayed(Duration.zero);
      expect(repository.segment, ['2026-07-20', 'A', 'B']);
      repository.frames.add({'other': 15});
      await Future<void>.delayed(Duration.zero);
      expect(frames.last.delay, Duration.zero);
      repository.frames.add({'123': 5, 'other': 15});
      await Future<void>.delayed(Duration.zero);
      expect(frames.last.delay, const Duration(minutes: 5));
      expect(frames.last.etaToAlight, const Duration(minutes: 35));
      repository.frames.addError(StateError('temporarily disconnected'));
      await Future<void>.delayed(const Duration(milliseconds: 15));
      expect(frames.last.delay, const Duration(minutes: 5));
    },
  );

  test(
    'THSR tracking emits its scheduled frame without a delay endpoint',
    () async {
      final now = DateTime(2026, 7, 20, 8, 30);
      final leg = JourneyLeg(
        kind: JourneyLegKind.thsr,
        routeLabel: '123',
        boardStop: 'A',
        alightStop: 'B',
        stopNames: const [],
        identity: const PlanIdentity.empty(),
        leadingWalkMinutes: 0,
        scheduledDeparture: null,
        scheduledArrival: null,
        boardLocation: const PlanPoint(lat: 0, lng: 0),
        stopLocations: const [],
        railSchedule: [
          RailStopSchedule(
            name: 'A',
            scheduledArrival: DateTime(2026, 7, 20, 8),
          ),
          RailStopSchedule(
            name: 'B',
            scheduledArrival: DateTime(2026, 7, 20, 9),
          ),
        ],
      );
      final frame = await defaultRailTrackStream(leg, now: () => now).first;
      expect(frame.etaToAlight, const Duration(minutes: 30));
      expect(frame.delay, Duration.zero);
      expect(frame.remainingStops, 1);
    },
  );
  test(
    'supported bus identity uses matching station arrivals in feed order',
    () async {
      final bus = _Bus();
      final leg = _leg(supported: true);
      bus.arrivals = [
        _arrival('other', 60),
        _arrival('307', 61),
        _arrival('307', 0),
      ];
      expect(
        await defaultLegEtaStream(leg, repository: bus).first,
        const Duration(minutes: 2),
      );
      expect(bus.station, 'S');
      expect(bus.route, isNull);
      bus.arrivals = [_arrival('307', 0)];
      expect(
        await defaultLegEtaStream(leg, repository: bus).first,
        Duration.zero,
      );
      bus.arrivals = [_arrival('other', 0), _arrival('307', -1, status: 3)];
      expect(await defaultLegEtaStream(leg, repository: bus).first, isNull);
      bus.arrivals = [];
      expect(await defaultLegEtaStream(leg, repository: bus).first, isNull);
    },
  );

  test(
    'route identities filter departure stop and direction '
    'without skipping unknown ETA',
    () async {
      final bus = _Bus();
      final leg = _leg();
      bus.etas = [
        _eta(stop: 'other', seconds: 20),
        _eta(direction: 1, seconds: 30),
        _eta(seconds: 45),
      ];
      expect(
        await defaultLegEtaStream(leg, repository: bus).first,
        const Duration(seconds: 45),
      );
      expect(bus.route, 'R');
      expect(bus.station, isNull);
      bus.etas = [_eta()];
      expect(
        await defaultLegEtaStream(leg, repository: bus).first,
        Duration.zero,
      );
      bus.etas = [_eta(status: 3), _eta(seconds: 30)];
      expect(await defaultLegEtaStream(leg, repository: bus).first, isNull);
      bus.etas = [_eta(direction: 1, seconds: 30)];
      expect(
        await defaultLegEtaStream(_leg(direction: ''), repository: bus).first,
        const Duration(seconds: 30),
      );
      bus.etas = [];
      expect(await defaultLegEtaStream(leg, repository: bus).first, isNull);
      expect(
        await defaultRouteEtaStream('route', repository: bus).first,
        isEmpty,
      );
      expect(bus.route, 'route');
    },
  );

  test(
    'unresolved and non-bus legs fall back to the scheduled departure',
    () async {
      final bus = _Bus();
      for (final leg in [
        _leg(route: ''),
        _leg(stop: '', supported: true),
        _leg(kind: JourneyLegKind.metro),
        _leg(kind: JourneyLegKind.tra),
      ]) {
        expect(await defaultLegEtaStream(leg, repository: bus).first, isNull);
      }
      expect(bus.route, isNull);
      expect(bus.station, isNull);
      final past = _leg(route: '', departure: DateTime(2000));
      expect(
        await defaultLegEtaStream(past, repository: bus).first,
        Duration.zero,
      );
      final future = DateTime.now().add(const Duration(minutes: 10));
      final eta = await defaultLegEtaStream(
        _leg(route: '', departure: future),
        repository: bus,
      ).first;
      expect(eta, greaterThan(const Duration(minutes: 9)));
      expect(eta, lessThanOrEqualTo(const Duration(minutes: 10)));
    },
  );
}
