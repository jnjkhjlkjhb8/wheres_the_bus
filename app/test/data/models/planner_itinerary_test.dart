import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protobuf/well_known_types/google/protobuf/timestamp.pb.dart';
import 'package:wheres_the_bus/data/generated/maas.pb.dart' as maas;
import 'package:wheres_the_bus/data/generated/planner.pb.dart';
import 'package:wheres_the_bus/data/models/plan_models.dart';
import 'package:wheres_the_bus/data/models/planner_itinerary.dart';

void main() {
  group('an itinerary restated as a route', () {
    final route = planRouteFromItinerary(_itinerary());

    test('carries the summary and the planner-only fields', () {
      expect(route.id, 'itin-1');
      expect(route.travelTime, 1800);
      expect(route.transfers, 1);
      expect(route.totalFare, 35);
      expect(route.fareComplete, isFalse);
      expect(route.walkSeconds, 420);
      expect(route.startTime, _local(8, 0));
      expect(route.endTime, _local(8, 30));
      expect(route.transferMargins, [
        const PlanTransfer(
          fromLeg: 1,
          toLeg: 3,
          marginSeconds: 360,
          reliability: TransferReliability.comfortable,
          timesEstimated: true,
        ),
      ]);
    });

    test('keeps one section per leg, in leg order', () {
      expect(route.sections.map((s) => s.type), [
        'pedestrian',
        'transit',
        'pedestrian',
        'transit',
      ]);
      expect(route.sections.map((s) => s.transport.mode), [
        '',
        'Bus',
        '',
        'Subway',
      ]);
    });

    test('a walk leg keeps its street geometry and steps', () {
      final walk = route.sections.first;
      expect(walk.departure.name, '目前位置');
      expect(walk.departure.type, 'place');
      expect(walk.departure.time, _local(8, 0));
      expect(walk.arrival.type, 'station');
      expect(walk.travelSummary.duration, 240);
      expect(walk.travelSummary.length, 280);
      expect(walk.walkPath, const [PlanPoint(lat: 25, lng: 121)]);
      expect(walk.transitPath, isEmpty);
      expect(walk.walkSteps.single.instruction, '直走');
      expect(walk.identity, const PlanIdentity.empty());
    });

    test('a transit leg keeps its line, stops, identity and fare', () {
      final bus = route.sections[1];
      expect(bus.transport.name, '262');
      expect(bus.transport.shortName, '262');
      expect(bus.transport.longName, '262 長');
      expect(bus.transport.headsign, '民生社區');
      expect(bus.transport.routeColor, 'ff0000');
      expect(bus.transport.category, '');
      expect(bus.intermediateStops.single.name, '中途');
      expect(bus.intermediateStops.single.departureTime, _local(8, 7));
      expect(bus.identity.routeKey, 'TPE262');
      expect(bus.fare, 15);
      expect(bus.transitPath, const [PlanPoint(lat: 25.1, lng: 121.1)]);
      expect(bus.walkPath, isEmpty);
      expect(bus.alternatives.single.transport.name, '262 區');
    });

    test('an unset time stays empty rather than becoming 1970', () {
      final stop = route.sections[3].intermediateStops.single;
      expect(stop.departureTime, '');
      expect(route.sections[3].arrival.time, '');
    });

    test('saves as the route bytes a saved snapshot has always held', () {
      final reopened = PlanRoute.fromBytes(route.raw!);
      expect(reopened.sections, route.sections);
      expect(reopened.startTime, route.startTime);
      // The bytes are the old shape, so what only the planner knows is gone.
      expect(reopened.id, '');
      expect(reopened.transferMargins, isEmpty);
      expect(reopened.fareComplete, isTrue);
      expect(reopened.walkSeconds, isNull);
      final sections = maas.Route.fromBuffer(route.raw!).sections;
      expect(sections, hasLength(4));
      // The operator travels with the ride and nowhere else.
      expect(sections[1].agency.name, '首都客運');
      expect(sections[1].hasNotificationIdentity(), isTrue);
      expect(sections[0].hasAgency(), isFalse);
      expect(sections[0].hasNotificationIdentity(), isFalse);
    });
  });

  test('the planner levels become reliability words to choose from', () {
    PlanTransfer from(TransferLevel level) =>
        PlanTransfer.fromProto(PlannerTransfer(level: level));
    expect(
      from(TransferLevel.TRANSFER_LEVEL_COMFORTABLE).reliability,
      TransferReliability.comfortable,
    );
    expect(
      from(TransferLevel.TRANSFER_LEVEL_TIGHT).reliability,
      TransferReliability.tight,
    );
    expect(
      from(TransferLevel.TRANSFER_LEVEL_UNSPECIFIED).reliability,
      TransferReliability.unknown,
    );
  });

  test('a response keeps its order and its paging cursors', () {
    final result = planResultFromPlanner(
      PlannerResponse(
        itineraries: [
          PlannerItinerary(id: 'a'),
          PlannerItinerary(id: 'b'),
        ],
        previousPageCursor: 'earlier',
        nextPageCursor: 'later',
      ),
    );
    expect(result.routes.map((r) => r.id), ['a', 'b']);
    expect(result.previousPageCursor, 'earlier');
    expect(result.nextPageCursor, 'later');
  });

  test('a clock time is the local wall time of the same moment', () {
    final route = planRouteFromItinerary(
      PlannerItinerary(startTime: _at(8, 5)),
    );
    final local = DateTime(2026, 11, 14, 8, 5);
    expect(route.startTime, startsWith('2026-11-14T08:05'));
    expect(DateTime.parse(route.startTime), local);
  });

  group('transfers on a route', () {
    const comfortable = PlanTransfer(
      fromLeg: 1,
      toLeg: 3,
      marginSeconds: 400,
      reliability: TransferReliability.comfortable,
      timesEstimated: false,
    );
    const tight = PlanTransfer(
      fromLeg: 3,
      toLeg: 5,
      marginSeconds: 130,
      reliability: TransferReliability.tight,
      timesEstimated: false,
    );
    const untimed = PlanTransfer(
      fromLeg: 5,
      toLeg: 7,
      marginSeconds: -900,
      reliability: TransferReliability.unknown,
      timesEstimated: false,
    );
    const route = PlanRoute(
      travelTime: 0,
      startTime: '',
      endTime: '',
      transfers: 3,
      sections: [],
      transferMargins: [comfortable, tight, untimed],
    );

    test('the weakest is the smallest margin the planner could time', () {
      expect(route.weakestTransfer, tight);
      const later = PlanRoute(
        travelTime: 0,
        startTime: '',
        endTime: '',
        transfers: 2,
        sections: [],
        transferMargins: [tight, comfortable],
      );
      expect(later.weakestTransfer, tight);
    });

    test('an untimed transfer is never the weakest or named at a leg', () {
      const onlyUntimed = PlanRoute(
        travelTime: 0,
        startTime: '',
        endTime: '',
        transfers: 1,
        sections: [],
        transferMargins: [untimed],
      );
      expect(onlyUntimed.weakestTransfer, isNull);
      expect(route.timedTransferInto(7), isNull);
    });

    test('a leg finds the change that leads into it', () {
      expect(route.timedTransferInto(3), comfortable);
      expect(route.timedTransferInto(5), tight);
      expect(route.timedTransferInto(1), isNull);
    });

    test('minutes round down and never go negative', () {
      expect(comfortable.marginMinutes, 6);
      expect(tight.marginMinutes, 2);
      expect(untimed.marginMinutes, 0);
      expect(comfortable.timed, isTrue);
      expect(comfortable.tight, isFalse);
      expect(tight.tight, isTrue);
      expect(untimed.timed, isFalse);
    });

    test('the planner fields take part in equality', () {
      const bare = PlanRoute(
        travelTime: 0,
        startTime: '',
        endTime: '',
        transfers: 3,
        sections: [],
      );
      expect(bare, isNot(route));
      expect(
        bare,
        isNot(
          const PlanRoute(
            travelTime: 0,
            startTime: '',
            endTime: '',
            transfers: 3,
            sections: [],
            id: 'x',
          ),
        ),
      );
      expect(
        bare,
        isNot(
          const PlanRoute(
            travelTime: 0,
            startTime: '',
            endTime: '',
            transfers: 3,
            sections: [],
            fareComplete: false,
          ),
        ),
      );
      expect(
        bare,
        isNot(
          const PlanRoute(
            travelTime: 0,
            startTime: '',
            endTime: '',
            transfers: 3,
            sections: [],
            walkSeconds: 0,
          ),
        ),
      );
      expect(comfortable, isNot(tight));
      expect(
        comfortable,
        isNot(
          const PlanTransfer(
            fromLeg: 1,
            toLeg: 3,
            marginSeconds: 400,
            reliability: TransferReliability.comfortable,
            timesEstimated: true,
          ),
        ),
      );
    });
  });

  test('a saved snapshot is never swapped for a result', () {
    const saved = PlanRoute(
      travelTime: 0,
      startTime: '',
      endTime: '',
      transfers: 0,
      sections: [],
    );
    const other = PlanRoute(
      travelTime: 1,
      startTime: '',
      endTime: '',
      transfers: 0,
      sections: [],
    );
    expect(saved.refreshedFrom([other]), same(saved));
  });
}

Timestamp _at(int hour, int minute) =>
    Timestamp.fromDateTime(DateTime(2026, 11, 14, hour, minute));

String _local(int hour, int minute) {
  final route = planRouteFromItinerary(
    PlannerItinerary(startTime: _at(hour, minute)),
  );
  return route.startTime;
}

PlannerStop _stop(String name, {String stopId = '', Timestamp? departure}) =>
    PlannerStop(
      name: name,
      stopId: stopId,
      location: maas.Location(lat: 25, lng: 121),
      departure: departure,
    );

PlannerItinerary _itinerary() => PlannerItinerary(
  id: 'itin-1',
  startTime: _at(8, 0),
  endTime: _at(8, 30),
  durationSeconds: Int64(1800),
  transferCount: 1,
  walkSeconds: Int64(420),
  totalFare: 35,
  fareComplete: false,
  legs: [
    PlannerLeg(
      kind: PlannerLegKind.PLANNER_LEG_KIND_WALK,
      from: _stop('目前位置'),
      to: _stop('民生敦化路口', stopId: 's1'),
      startTime: _at(8, 0),
      endTime: _at(8, 4),
      durationSeconds: Int64(240),
      distanceMeters: 280,
      path: [maas.Location(lat: 25, lng: 121)],
      walkSteps: [maas.WalkStep(instruction: '直走')],
    ),
    PlannerLeg(
      kind: PlannerLegKind.PLANNER_LEG_KIND_TRANSIT,
      mode: PlannerTransitMode.PLANNER_TRANSIT_MODE_BUS,
      from: _stop('民生敦化路口', stopId: 's1'),
      to: _stop('捷運忠孝復興站', stopId: 's2'),
      startTime: _at(8, 4),
      endTime: _at(8, 15),
      durationSeconds: Int64(660),
      transit: PlannerTransit(
        name: '262',
        shortName: '262',
        longName: '262 長',
        headsign: '民生社區',
        routeColor: 'ff0000',
        agency: maas.Agency(name: '首都客運'),
      ),
      intermediateStops: [_stop('中途', departure: _at(8, 7))],
      notificationIdentity: maas.NotificationIdentity(routeKey: 'TPE262'),
      fare: 15,
      path: [maas.Location(lat: 25.1, lng: 121.1)],
      alternatives: [
        PlannerLeg(
          kind: PlannerLegKind.PLANNER_LEG_KIND_TRANSIT,
          mode: PlannerTransitMode.PLANNER_TRANSIT_MODE_BUS,
          transit: PlannerTransit(name: '262 區'),
        ),
      ],
    ),
    PlannerLeg(
      kind: PlannerLegKind.PLANNER_LEG_KIND_WALK,
      startTime: _at(8, 15),
      endTime: _at(8, 20),
    ),
    PlannerLeg(
      kind: PlannerLegKind.PLANNER_LEG_KIND_TRANSIT,
      mode: PlannerTransitMode.PLANNER_TRANSIT_MODE_SUBWAY,
      startTime: _at(8, 21),
      transit: PlannerTransit(name: 'BR'),
      intermediateStops: [_stop('松山機場')],
    ),
  ],
  transfers: [
    PlannerTransfer(
      fromLeg: 1,
      toLeg: 3,
      marginSeconds: Int64(360),
      level: TransferLevel.TRANSFER_LEVEL_COMFORTABLE,
      timesEstimated: true,
    ),
  ],
);
