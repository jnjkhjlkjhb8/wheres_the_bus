import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/generated/maas.pb.dart' as maas;
import 'package:wheres_the_bus/data/models/plan_models.dart';

maas.Route _fixture({String endTime = '2026-07-11T08:30:00'}) => maas.Route(
  startTime: '2026-07-11T08:00:00',
  endTime: endTime,
  transfers: 1,
  totalFare: 30,
  sections: [
    maas.Section(
      type: 'transit',
      departure: maas.Place(name: '台北車站'),
      arrival: maas.Place(name: '市政府站'),
    ),
  ],
);

void main() {
  test('saved snapshot round-trips through raw bytes', () {
    final original = PlanRoute.fromProto(_fixture());
    expect(original.raw, isNotNull);

    final restored = PlanRoute.fromBytes(original.raw!);

    expect(restored.startTime, original.startTime);
    expect(restored.endTime, original.endTime);
    expect(restored.travelTime, original.travelTime);
    expect(restored.transfers, original.transfers);
    expect(restored.totalFare, original.totalFare);
    expect(restored.sections.first.departure.name, '台北車站');
    expect(restored.sections.last.arrival.name, '市政府站');
    // Equatable content (raw excluded from props) matches.
    expect(restored, original);
    // Re-serialization is deterministic, so keys match across the round-trip.
    expect(restored.raw, original.raw);
    expect(restored.savedKey, original.savedKey);
  });

  test('savedKey dedups identical content but separates siblings', () {
    final a = PlanRoute.fromProto(_fixture());
    final b = PlanRoute.fromBytes(a.raw!);
    // A sibling option sharing origin, dest and departure time but a different
    // arrival — the field key would have collided; the byte key must not.
    final sibling = PlanRoute.fromProto(
      _fixture(endTime: '2026-07-11T08:45:00'),
    );

    expect(a.savedKey, b.savedKey); // same content → one entry
    expect({a.savedKey, b.savedKey}.length, 1);
    expect(a.savedKey, isNot(sibling.savedKey)); // distinct options
  });

  test('walk path and steps map from proto and survive the round-trip', () {
    final route = maas.Route(
      sections: [
        maas.Section(
          type: 'walk',
          departure: maas.Place(
            name: '起點',
            location: maas.Location(lat: 25, lng: 121.5),
          ),
          arrival: maas.Place(
            name: '終點',
            location: maas.Location(lat: 25.02, lng: 121.52),
          ),
          walkPath: [
            maas.Location(lat: 25, lng: 121.5),
            maas.Location(lat: 25.01, lng: 121.51),
          ],
          walkSteps: [
            maas.WalkStep(
              instruction: '左轉進入市民大道三段',
              maneuverType: 'turn',
              modifier: 'left',
              distanceMeters: 30,
              durationSeconds: Int64(25),
              location: maas.Location(lat: 25.01, lng: 121.51),
            ),
          ],
        ),
      ],
    );

    final mapped = PlanRoute.fromProto(route).sections.first;
    expect(mapped.walkPath, hasLength(2));
    expect(mapped.walkPath.first.lat, 25.0);
    expect(mapped.walkSteps, hasLength(1));
    final step = mapped.walkSteps.first;
    expect(step.instruction, '左轉進入市民大道三段');
    expect(step.maneuverType, 'turn');
    expect(step.modifier, 'left');
    expect(step.distanceMeters, 30);
    expect(step.durationSeconds, 25);
    expect(step.location.lng, 121.51);

    // Round-trip through the raw snapshot bytes preserves the walk enrichment.
    final restored = PlanRoute.fromBytes(
      PlanRoute.fromProto(route).raw!,
    ).sections.first;
    expect(restored.walkPath, hasLength(2));
    expect(restored.walkSteps.first.instruction, '左轉進入市民大道三段');
  });

  test('savedKey falls back to a field key without raw bytes', () {
    const route = PlanRoute(
      travelTime: 0,
      startTime: '2026-07-11T08:00:00',
      endTime: '2026-07-11T08:30:00',
      transfers: 0,
      sections: [],
    );
    expect(route.savedKey, '||2026-07-11T08:00:00');
  });
}
