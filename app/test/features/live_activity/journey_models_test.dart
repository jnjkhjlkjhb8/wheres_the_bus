import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/models/plan_models.dart';
import 'package:wheres_the_bus/data/tracking/journey_models.dart';

PlanSection _section({
  required String type,
  String mode = '',
  String shortName = '',
  String headsign = '',
  String depName = '起點',
  String arrName = '終點',
  String depTime = '2026-07-06T10:00:00+08:00',
  int walkSeconds = 0,
  PlanIdentity identity = const PlanIdentity.empty(),
  List<PlanStop> stops = const [],
}) {
  return PlanSection(
    type: type,
    travelSummary: PlanTravelSummary(duration: walkSeconds, length: 0),
    departure: PlanPlace(
      name: depName,
      type: 'station',
      location: const PlanPoint(lat: 25, lng: 121.5),
      time: depTime,
    ),
    arrival: PlanPlace(
      name: arrName,
      type: 'station',
      location: const PlanPoint(lat: 25.1, lng: 121.6),
      time: '2026-07-06T10:30:00+08:00',
    ),
    transport: PlanTransport(
      mode: mode,
      name: shortName,
      shortName: shortName,
      longName: '',
      headsign: headsign,
      category: '',
      routeColor: '',
    ),
    intermediateStops: stops,
    identity: identity,
  );
}

void main() {
  group('JourneyLeg.legsFromRoute', () {
    test('folds a leading walk into the next transit leg', () {
      final route = PlanRoute(
        travelTime: 1800,
        startTime: '2026-07-06T09:55:00+08:00',
        endTime: '2026-07-06T10:30:00+08:00',
        transfers: 0,
        sections: [
          _section(type: 'pedestrian', walkSeconds: 300),
          _section(
            type: 'transit',
            mode: 'bus',
            shortName: '307',
            headsign: '板橋',
            identity: const PlanIdentity(
              routeType: 'bus',
              routeKey: 'TPE307',
              direction: '0',
              departureStopKey: 'Taipei:STOP1',
              arrivalStopKey: 'Taipei:STOP9',
              supported: true,
            ),
          ),
        ],
      );

      final legs = JourneyLeg.legsFromRoute(route);
      expect(legs, hasLength(1));
      expect(legs.first.kind, JourneyLegKind.bus);
      expect(legs.first.routeLabel, '307 往板橋');
      expect(legs.first.leadingWalkMinutes, 5);
      expect(legs.first.boardStop, '起點');
      expect(legs.first.identity.supported, isTrue);
      expect(legs.first.scheduledDeparture, isNotNull);
    });

    test('maps rail modes and keeps stop names for progress', () {
      final route = PlanRoute(
        travelTime: 3600,
        startTime: '',
        endTime: '',
        transfers: 1,
        sections: [
          _section(
            type: 'transit',
            mode: 'train',
            shortName: '自強123',
            identity: const PlanIdentity(
              routeType: 'tra',
              routeKey: '123',
              direction: '0',
              departureStopKey: '1000',
              arrivalStopKey: '3300',
              supported: false,
            ),
            stops: const [
              PlanStop(
                name: '中壢',
                location: PlanPoint(lat: 24.9, lng: 121.2),
                departureTime: '',
              ),
            ],
          ),
          _section(
            type: 'transit',
            mode: 'subway',
            shortName: '板南線',
            identity: const PlanIdentity(
              routeType: 'mrt',
              routeKey: 'TRTC:BL',
              direction: '0',
              departureStopKey: 'BL12',
              arrivalStopKey: 'BL15',
              supported: false,
            ),
          ),
        ],
      );

      final legs = JourneyLeg.legsFromRoute(route);
      expect(legs, hasLength(2));
      expect(legs[0].kind, JourneyLegKind.tra);
      expect(legs[0].stopNames, ['中壢']);
      expect(legs[1].kind, JourneyLegKind.metro);
      expect(legs[1].leadingWalkMinutes, 0);
    });

    test('walking-only route yields no legs', () {
      final route = PlanRoute(
        travelTime: 600,
        startTime: '',
        endTime: '',
        transfers: 0,
        sections: [_section(type: 'pedestrian', walkSeconds: 600)],
      );
      expect(JourneyLeg.legsFromRoute(route), isEmpty);
    });
  });
}
