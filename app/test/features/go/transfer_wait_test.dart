import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/models/plan_models.dart';
import 'package:wheres_the_bus/features/go/widgets/route_option_card.dart';

const _transport = PlanTransport(
  mode: 'BUS',
  name: '',
  shortName: '',
  longName: '',
  headsign: '',
  category: '',
  routeColor: '',
);

const _here = PlanPoint(lat: 25, lng: 121.5);

PlanSection _section({
  required String type,
  required String departure,
  required String arrival,
  int duration = 0,
}) => PlanSection(
  type: type,
  travelSummary: PlanTravelSummary(duration: duration, length: 0),
  departure: PlanPlace(
    name: 'from',
    type: 'place',
    location: _here,
    time: departure,
  ),
  arrival: PlanPlace(name: 'to', type: 'place', location: _here, time: arrival),
  transport: _transport,
  intermediateStops: const [],
);

void main() {
  test(
    'the gap between one section arriving and the next departing is wait',
    () {
      // Walk 08:00→08:05, bus departs 08:17: 12 minutes standing at the stop.
      final sections = [
        _section(
          type: 'pedestrian',
          departure: '2026-07-30T08:00:00+08:00',
          arrival: '2026-07-30T08:05:00+08:00',
          duration: 300,
        ),
        _section(
          type: 'transit',
          departure: '2026-07-30T08:17:00+08:00',
          arrival: '2026-07-30T08:40:00+08:00',
          duration: 1380,
        ),
      ];

      expect(waitMinutesBefore(sections, 1), 12);
      expect(
        waitMinutesBefore(sections, 0),
        0,
        reason: 'nothing precedes the first section',
      );
    },
  );

  test(
    'a same-platform transfer with no walk between still reports its wait',
    () {
      final sections = [
        _section(
          type: 'transit',
          departure: '2026-07-30T08:00:00+08:00',
          arrival: '2026-07-30T08:20:00+08:00',
        ),
        _section(
          type: 'transit',
          departure: '2026-07-30T08:24:00+08:00',
          arrival: '2026-07-30T08:50:00+08:00',
        ),
      ];

      expect(waitMinutesBefore(sections, 1), 4);
    },
  );

  test(
    'a UTC arrival against a local departure is not eight hours of wait',
    () {
      final sections = [
        _section(
          type: 'pedestrian',
          departure: '2026-07-30T00:00:00Z',
          arrival: '2026-07-30T00:05:00Z',
        ),
        _section(
          type: 'transit',
          departure: '2026-07-30T08:17:00+08:00',
          arrival: '2026-07-30T08:40:00+08:00',
        ),
      ];

      expect(waitMinutesBefore(sections, 1), 12);
    },
  );

  test('missing, unparseable and negative gaps report no wait', () {
    final blank = [
      _section(type: 'pedestrian', departure: '', arrival: ''),
      _section(type: 'transit', departure: '', arrival: ''),
    ];
    expect(waitMinutesBefore(blank, 1), 0);

    final garbage = [
      _section(type: 'pedestrian', departure: 'now', arrival: 'later'),
      _section(type: 'transit', departure: 'soon', arrival: 'eventually'),
    ];
    expect(waitMinutesBefore(garbage, 1), 0);

    // Overlapping legs (upstream data error) must never read as negative wait.
    final overlapping = [
      _section(
        type: 'transit',
        departure: '2026-07-30T08:00:00+08:00',
        arrival: '2026-07-30T08:30:00+08:00',
      ),
      _section(
        type: 'transit',
        departure: '2026-07-30T08:25:00+08:00',
        arrival: '2026-07-30T08:50:00+08:00',
      ),
    ];
    expect(waitMinutesBefore(overlapping, 1), 0);
  });

  test('route total sums every transfer, and walk time excludes it', () {
    final route = PlanRoute(
      travelTime: 3000,
      startTime: '2026-07-30T08:00:00+08:00',
      endTime: '2026-07-30T08:50:00+08:00',
      transfers: 1,
      sections: [
        _section(
          type: 'pedestrian',
          departure: '2026-07-30T08:00:00+08:00',
          arrival: '2026-07-30T08:05:00+08:00',
          duration: 300,
        ),
        _section(
          type: 'transit',
          departure: '2026-07-30T08:17:00+08:00',
          arrival: '2026-07-30T08:35:00+08:00',
          duration: 1080,
        ),
        _section(
          type: 'transit',
          departure: '2026-07-30T08:39:00+08:00',
          arrival: '2026-07-30T08:50:00+08:00',
          duration: 660,
        ),
      ],
    );

    expect(
      waitMinutes(route),
      16,
      reason: '12 at the first stop plus 4 to transfer',
    );
    expect(
      walkMinutes(route),
      5,
      reason: 'the walk keeps only its own duration',
    );
  });
}
