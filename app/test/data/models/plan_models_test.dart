import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/generated/maas.pb.dart' as maas;
import 'package:wheres_the_bus/data/models/plan_models.dart';

PlanPlace place(double lat, double lng) => PlanPlace(
  name: 'p',
  type: 'place',
  location: PlanPoint(lat: lat, lng: lng),
  time: '',
);

PlanSection section(
  PlanPlace from,
  PlanPlace to, {
  List<PlanStop> stops = const [],
}) => PlanSection(
  type: 'transit',
  travelSummary: const PlanTravelSummary(duration: 60, length: 100),
  departure: from,
  arrival: to,
  transport: const PlanTransport(
    mode: 'bus',
    name: '',
    shortName: '',
    longName: '',
    headsign: '',
    category: '',
    routeColor: '',
  ),
  intermediateStops: stops,
);

PlanRoute route(List<PlanSection> sections) => PlanRoute(
  travelTime: 600,
  startTime: '08:00',
  endTime: '08:10',
  transfers: 0,
  sections: sections,
);

void main() {
  test('firstPoint returns departure of requested leg', () {
    final r = route([
      section(place(25, 121.5), place(25.1, 121.6)),
      section(place(25.1, 121.6), place(25.2, 121.7)),
    ]);
    expect(r.firstPoint(), const PlanPoint(lat: 25, lng: 121.5));
    expect(r.firstPoint(leg: 1), const PlanPoint(lat: 25.1, lng: 121.6));
  });

  test('firstPoint is null for out-of-range leg or zero location', () {
    final r = route([section(place(0, 0), place(25.1, 121.6))]);
    expect(r.firstPoint(), isNull);
    expect(r.firstPoint(leg: 5), isNull);
  });

  test('points flattens sections and drops zero coordinates', () {
    final r = route([
      section(
        place(25, 121.5),
        place(25.2, 121.7),
        stops: [
          const PlanStop(
            name: 's1',
            location: PlanPoint(lat: 25.1, lng: 121.6),
            departureTime: '',
          ),
          const PlanStop(
            name: 'zero',
            location: PlanPoint(lat: 0, lng: 0),
            departureTime: '',
          ),
        ],
      ),
    ]);
    expect(r.points, const [
      PlanPoint(lat: 25, lng: 121.5),
      PlanPoint(lat: 25.1, lng: 121.6),
      PlanPoint(lat: 25.2, lng: 121.7),
    ]);
  });

  _cursorsAndAlternatives();
}

void _cursorsAndAlternatives() {
  test('paging cursors survive the wire', () {
    final result = PlanResult.fromProto(
      maas.MaasPlanResponse(
        previousPageCursor: 'EARLIER-1',
        nextPageCursor: 'LATER-1',
      ),
    );
    expect(result.previousPageCursor, 'EARLIER-1');
    expect(result.nextPageCursor, 'LATER-1');
  });

  test('a planner that does not page leaves both cursors empty', () {
    final result = PlanResult.fromProto(maas.MaasPlanResponse());
    // Empty is what tells the results list not to offer the action at all —
    // a button that leads nowhere is worse than no button.
    expect(result.previousPageCursor, isEmpty);
    expect(result.nextPageCursor, isEmpty);
  });

  test('a leg carries the other services that could replace it', () {
    final section = PlanSection.fromProto(
      maas.Section(
        type: 'transit',
        transport: maas.Transport(mode: 'BUS', shortName: '307'),
        alternatives: [
          maas.Section(
            type: 'transit',
            transport: maas.Transport(mode: 'BUS', shortName: '310'),
            departure: maas.Place(name: 'A', time: '07:21'),
            arrival: maas.Place(name: 'B', time: '07:40'),
            notificationIdentity: maas.NotificationIdentity(
              routeType: 'bus',
              routeKey: 'BUS-310',
              supported: true,
            ),
          ),
          maas.Section(
            type: 'transit',
            transport: maas.Transport(mode: 'MRT', shortName: '板南線'),
            departure: maas.Place(name: 'A', time: '07:24'),
            arrival: maas.Place(name: 'B', time: '07:38'),
            notificationIdentity: maas.NotificationIdentity(),
          ),
        ],
      ),
    );

    expect(section.alternatives, hasLength(2));
    expect(section.alternatives.first.transport.shortName, '310');
    expect(section.alternatives.first.departure.time, '07:21');
    // Resolved identity is what makes an alternative tappable through to the
    // route screen; the metro one has none, so it stays a plain row.
    expect(section.alternatives.first.identity.supported, isTrue);
    expect(section.alternatives.first.identity.routeKey, 'BUS-310');
    expect(section.alternatives.last.identity.supported, isFalse);
    // Alternatives never nest — the app must not have to recurse.
    expect(section.alternatives.first.alternatives, isEmpty);
  });

  test('a leg with no alternatives asked for carries none', () {
    final section = PlanSection.fromProto(maas.Section(type: 'transit'));
    expect(section.alternatives, isEmpty);
  });
}
