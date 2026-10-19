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
  test('saved keys distinguish byte snapshots and named routes', () {
    PlanRoute snapshot(List<int> raw) => PlanRoute(
      travelTime: 0,
      startTime: '08:00',
      endTime: '08:10',
      transfers: 0,
      sections: const [],
      raw: raw,
    );
    expect(snapshot([]).savedKey, 'r2166136261');
    expect(snapshot([1, 2, 3]).savedKey, 'r1456420779');
    expect(snapshot([1, 2, 3]).savedKey, snapshot([1, 2, 3]).savedKey);
    expect(snapshot([1, 2, 4]).savedKey, isNot(snapshot([1, 2, 3]).savedKey));
    expect(route([]).savedKey, '||08:00');
    expect(
      route([section(place(25, 121), place(26, 122))]).savedKey,
      'p|p|08:00',
    );
  });

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
  _publicPlannerValueContracts();
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

void _expectPlannerValue<T>(T original, T equal, List<T> differences) {
  expect(identical(original, equal), isFalse);
  expect(original, equal);
  expect(original.hashCode, equal.hashCode);
  expect({original, equal}, hasLength(1));
  for (final different in differences) {
    expect(different, isNot(original));
  }
  expect({original, ...differences}, hasLength(differences.length + 1));
}

PlanPoint _valuePoint({double lat = 25, double lng = 121}) =>
    PlanPoint(lat: lat, lng: lng);

PlanPlace _valuePlace({
  String name = 'Origin',
  String type = 'station',
  PlanPoint? location,
  String time = '08:00',
}) => PlanPlace(
  name: name,
  type: type,
  location: location ?? _valuePoint(),
  time: time,
);

PlanTravelSummary _valueSummary({int duration = 91, double length = 180.5}) =>
    PlanTravelSummary(duration: duration, length: length);

PlanTransport _valueTransport({
  String mode = 'bus',
  String name = '307 市區公車',
  String shortName = '307',
  String longName = '往板橋',
  String headsign = '板橋',
  String category = '市區公車',
  String routeColor = '#003366',
}) => PlanTransport(
  mode: mode,
  name: name,
  shortName: shortName,
  longName: longName,
  headsign: headsign,
  category: category,
  routeColor: routeColor,
);

PlanStop _valueStop({
  String name = 'Stop',
  PlanPoint? location,
  String departureTime = '08:01',
}) => PlanStop(
  name: name,
  location: location ?? _valuePoint(),
  departureTime: departureTime,
);

PlanWalkStep _valueWalkStep({
  String instruction = '左轉進入市民大道',
  String maneuverType = 'turn',
  String modifier = 'left',
  double distanceMeters = 30.5,
  int durationSeconds = 25,
  PlanPoint? location,
}) => PlanWalkStep(
  instruction: instruction,
  maneuverType: maneuverType,
  modifier: modifier,
  distanceMeters: distanceMeters,
  durationSeconds: durationSeconds,
  location: location ?? _valuePoint(),
);

PlanIdentity _valueIdentity({
  String routeType = 'bus',
  String routeKey = 'BUS-307',
  String direction = '0',
  String departureStopKey = 'A',
  String arrivalStopKey = 'B',
  bool supported = true,
}) => PlanIdentity(
  routeType: routeType,
  routeKey: routeKey,
  direction: direction,
  departureStopKey: departureStopKey,
  arrivalStopKey: arrivalStopKey,
  supported: supported,
);

PlanSection _valueSection({
  String type = 'transit',
  PlanTravelSummary? travelSummary,
  PlanPlace? departure,
  PlanPlace? arrival,
  PlanTransport? transport,
  List<PlanStop>? intermediateStops,
  PlanIdentity? identity,
  int fare = 30,
  List<PlanPoint>? walkPath,
  List<PlanWalkStep>? walkSteps,
  List<PlanPoint>? transitPath,
  List<PlanSection> alternatives = const [],
}) => PlanSection(
  type: type,
  travelSummary: travelSummary ?? _valueSummary(),
  departure: departure ?? _valuePlace(),
  arrival: arrival ?? _valuePlace(name: 'Destination'),
  transport: transport ?? _valueTransport(),
  intermediateStops: intermediateStops ?? [_valueStop()],
  identity: identity ?? _valueIdentity(),
  fare: fare,
  walkPath: walkPath ?? [_valuePoint(), _valuePoint(lat: 26)],
  walkSteps: walkSteps ?? [_valueWalkStep()],
  transitPath: transitPath ?? [_valuePoint(), _valuePoint(lng: 122)],
  alternatives: alternatives,
);

PlanRoute _valueRoute({
  int travelTime = 600,
  String startTime = '08:00',
  String endTime = '08:10',
  int transfers = 1,
  int totalFare = 30,
  List<PlanSection>? sections,
  List<int>? raw,
}) => PlanRoute(
  travelTime: travelTime,
  startTime: startTime,
  endTime: endTime,
  transfers: transfers,
  totalFare: totalFare,
  sections: sections ?? [_valueSection()],
  raw: raw,
);

void _publicPlannerValueContracts() {
  test('firstPoint accepts a nonzero longitude or latitude independently', () {
    final equator = route([section(place(0, 121), place(25, 121))]);
    final meridian = route([section(place(25, 0), place(25, 121))]);
    expect(equator.firstPoint(), const PlanPoint(lat: 0, lng: 121));
    expect(meridian.firstPoint(), const PlanPoint(lat: 25, lng: 0));
  });

  test('firstPoint returns null at the exact end of the leg list', () {
    final r = route([
      section(place(25, 121), place(26, 122)),
      section(place(26, 122), place(27, 123)),
    ]);
    expect(r.firstPoint(leg: 2), isNull);
    expect(route([]).firstPoint(), isNull);
  });

  test('points keep axis coordinates and shared stops in itinerary order', () {
    final r = route([
      section(
        place(0, 121),
        place(26, 122),
        stops: [
          PlanStop(
            name: 'meridian',
            location: _valuePoint(lng: 0),
            departureTime: '',
          ),
          PlanStop(
            name: 'missing',
            location: _valuePoint(lat: 0, lng: 0),
            departureTime: '',
          ),
        ],
      ),
      section(place(26, 122), place(27, 123)),
    ]);
    expect(r.points, const [
      PlanPoint(lat: 0, lng: 121),
      PlanPoint(lat: 25, lng: 0),
      PlanPoint(lat: 26, lng: 122),
      PlanPoint(lat: 26, lng: 122),
      PlanPoint(lat: 27, lng: 123),
    ]);
  });

  test('a named saved key uses the itinerary endpoints and departure time', () {
    final legs = [
      _valueSection(
        departure: _valuePlace(name: 'A'),
        arrival: _valuePlace(name: 'B'),
      ),
      _valueSection(
        departure: _valuePlace(name: 'B'),
        arrival: _valuePlace(name: 'C'),
      ),
    ];
    expect(_valueRoute(sections: legs).savedKey, 'A|C|08:00');
    expect(
      _valueRoute(sections: legs, startTime: '08:01').savedKey,
      'A|C|08:01',
    );
  });

  test(
    'route collections and independent paging cursors distinguish results',
    () {
      _expectPlannerValue(
        PlanResult(
          routes: [_valueRoute()],
          previousPageCursor: 'earlier',
          nextPageCursor: 'later',
        ),
        PlanResult(
          routes: [_valueRoute()],
          previousPageCursor: 'earlier',
          nextPageCursor: 'later',
        ),
        [
          PlanResult(
            routes: [_valueRoute(startTime: '09:00')],
            previousPageCursor: 'earlier',
            nextPageCursor: 'later',
          ),
          PlanResult(
            routes: [_valueRoute()],
            previousPageCursor: 'before',
            nextPageCursor: 'later',
          ),
          PlanResult(
            routes: [_valueRoute()],
            previousPageCursor: 'earlier',
            nextPageCursor: 'after',
          ),
          const PlanResult(
            routes: [],
            previousPageCursor: 'earlier',
            nextPageCursor: 'later',
          ),
        ],
      );
    },
  );

  test(
    'route value fields distinguish results while raw storage stays incidental',
    () {
      _expectPlannerValue(_valueRoute(raw: [1]), _valueRoute(raw: [2]), [
        _valueRoute(travelTime: 601),
        _valueRoute(startTime: '09:00'),
        _valueRoute(endTime: '09:10'),
        _valueRoute(transfers: 2),
        _valueRoute(totalFare: 31),
        _valueRoute(sections: [_valueSection(type: 'walk')]),
        _valueRoute(sections: []),
        _valueRoute(
          sections: [
            _valueSection(),
            _valueSection(type: 'walk'),
          ],
        ),
      ]);
    },
  );

  test('every leg value and geometry collection distinguishes sections', () {
    _expectPlannerValue(_valueSection(), _valueSection(), [
      _valueSection(type: 'walk'),
      _valueSection(travelSummary: _valueSummary(duration: 92)),
      _valueSection(departure: _valuePlace(name: 'Other origin')),
      _valueSection(arrival: _valuePlace(name: 'Other destination')),
      _valueSection(transport: _valueTransport(name: 'Other bus')),
      _valueSection(intermediateStops: [_valueStop(name: 'Other stop')]),
      _valueSection(identity: _valueIdentity(routeKey: 'BUS-310')),
      _valueSection(fare: 31),
      _valueSection(walkPath: [_valuePoint(lat: 27)]),
      _valueSection(walkSteps: [_valueWalkStep(instruction: '直行')]),
      _valueSection(transitPath: [_valuePoint(lng: 123)]),
      _valueSection(alternatives: [_valueSection(type: 'walk')]),
      _valueSection(intermediateStops: []),
      _valueSection(walkPath: []),
      _valueSection(walkPath: [_valuePoint(lat: 26), _valuePoint()]),
      _valueSection(walkSteps: []),
      _valueSection(transitPath: []),
      _valueSection(transitPath: [_valuePoint(lng: 122), _valuePoint()]),
    ]);
  });

  test('walk instructions preserve each independently observable value', () {
    _expectPlannerValue(_valueWalkStep(), _valueWalkStep(), [
      _valueWalkStep(instruction: '直行'),
      _valueWalkStep(maneuverType: 'arrive'),
      _valueWalkStep(modifier: 'right'),
      _valueWalkStep(distanceMeters: 31),
      _valueWalkStep(durationSeconds: 26),
      _valueWalkStep(location: _valuePoint(lat: 26)),
    ]);
  });

  test(
    'notification identity preserves all routing and support distinctions',
    () {
      _expectPlannerValue(_valueIdentity(), _valueIdentity(), [
        _valueIdentity(routeType: 'rail'),
        _valueIdentity(routeKey: 'BUS-310'),
        _valueIdentity(direction: '1'),
        _valueIdentity(departureStopKey: 'C'),
        _valueIdentity(arrivalStopKey: 'D'),
        _valueIdentity(supported: false),
        const PlanIdentity.empty(),
      ]);
    },
  );

  test('travel duration and distance each distinguish a summary', () {
    _expectPlannerValue(_valueSummary(), _valueSummary(), [
      _valueSummary(duration: 92),
      _valueSummary(length: 181),
    ]);
  });

  test('place name type coordinates and time each distinguish a location', () {
    _expectPlannerValue(_valuePlace(), _valuePlace(), [
      _valuePlace(name: 'Other'),
      _valuePlace(type: 'address'),
      _valuePlace(location: _valuePoint(lat: 26)),
      _valuePlace(time: '08:01'),
    ]);
  });

  test('both geographical coordinate axes distinguish point values', () {
    _expectPlannerValue(_valuePoint(), _valuePoint(), [
      _valuePoint(lat: 26),
      _valuePoint(lng: 122),
    ]);
  });

  test('transport display and routing fields each distinguish services', () {
    _expectPlannerValue(_valueTransport(), _valueTransport(), [
      _valueTransport(mode: 'rail'),
      _valueTransport(name: 'Other'),
      _valueTransport(shortName: '310'),
      _valueTransport(longName: '往台北'),
      _valueTransport(headsign: '台北'),
      _valueTransport(category: '快速公車'),
      _valueTransport(routeColor: '#224466'),
    ]);
  });

  test(
    'intermediate stop name coordinates and departure each distinguish stops',
    () {
      _expectPlannerValue(_valueStop(), _valueStop(), [
        _valueStop(name: 'Other'),
        _valueStop(location: _valuePoint(lat: 26)),
        _valueStop(departureTime: '08:02'),
      ]);
    },
  );
}
