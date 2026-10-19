import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:wheres_the_bus/shared/map/bus_heading.dart';

// bus_heading.dart: the two pure bits behind a live bus's marker rotation —
// deriving a heading when TDX doesn't give a usable one, and turning to a new
// one the short way round.
void main() {
  const taipei = LatLng(25.0416, 121.5501);

  group('bearingIfMoved', () {
    test('refuses a move inside the noise floor', () {
      // ~2 m north: a parked bus's GPS wander, not a direction of travel.
      expect(
        bearingIfMoved(taipei, const LatLng(25.041618, 121.5501)),
        isNull,
      );
    });

    test('reads the cardinal directions', () {
      // ~1 km out on each axis, well clear of the 5 m floor.
      expect(
        bearingIfMoved(taipei, const LatLng(25.0506, 121.5501)),
        closeTo(0, 0.5),
      );
      expect(
        bearingIfMoved(taipei, const LatLng(25.0416, 121.5600)),
        closeTo(90, 0.5),
      );
      expect(
        bearingIfMoved(taipei, const LatLng(25.0326, 121.5501)),
        closeTo(180, 0.5),
      );
      expect(
        bearingIfMoved(taipei, const LatLng(25.0416, 121.5402)),
        closeTo(270, 0.5),
      );
    });

    test('returns a compass value, never a negative one', () {
      // South-west: atan2 gives about -135 here, which Marker.rotation would
      // read as a legal but confusing angle to interpolate through.
      final bearing = bearingIfMoved(taipei, const LatLng(25.0326, 121.5402));
      expect(bearing, closeTo(225, 1));
    });

    test('honours a caller-raised floor', () {
      // ~100 m north: a real move, but below a 200 m threshold.
      const north100m = LatLng(25.0425, 121.5501);
      expect(bearingIfMoved(taipei, north100m), closeTo(0, 0.5));
      expect(bearingIfMoved(taipei, north100m, minMeters: 200), isNull);
    });
  });

  group('bearingIfMoved precision', () {
    const origin = LatLng(0, 0);

    test('reads the intercardinal directions exactly', () {
      expect(bearingIfMoved(origin, const LatLng(0.001, 0.001)), closeTo(45, 1e-9));
      expect(bearingIfMoved(origin, const LatLng(-0.001, 0.001)), closeTo(135, 1e-9));
      expect(bearingIfMoved(origin, const LatLng(-0.001, -0.001)), closeTo(225, 1e-9));
      expect(bearingIfMoved(origin, const LatLng(0.001, -0.001)), closeTo(315, 1e-9));
      expect(bearingIfMoved(origin, const LatLng(0.001, 0)), closeTo(0, 1e-9));
      expect(bearingIfMoved(origin, const LatLng(0, 0.001)), closeTo(90, 1e-9));
      expect(bearingIfMoved(origin, const LatLng(-0.001, 0)), closeTo(180, 1e-9));
      expect(bearingIfMoved(origin, const LatLng(0, -0.001)), closeTo(270, 1e-9));
    });

    test('a degree of latitude is 111320 metres', () {
      const oneDegreeNorth = LatLng(1, 0);
      expect(bearingIfMoved(origin, oneDegreeNorth, minMeters: 111319.5), 0);
      expect(bearingIfMoved(origin, oneDegreeNorth, minMeters: 111320.5), isNull);
    });

    test('a move of exactly the floor still counts', () {
      expect(bearingIfMoved(origin, const LatLng(1, 0), minMeters: 111320), 0);
    });

    test('the default floor is five metres', () {
      // 0.000045 degrees of latitude is 5.0094 m; 0.000044 is 4.898 m.
      expect(bearingIfMoved(origin, const LatLng(0.000045, 0)), 0);
      expect(bearingIfMoved(origin, const LatLng(0.000044, 0)), isNull);
    });

    test('east-west distance shrinks with the cosine of the latitude', () {
      const sixty = LatLng(60, 0);
      const east = LatLng(60, 1);
      expect(bearingIfMoved(sixty, east, minMeters: 55659), closeTo(90, 1e-9));
      expect(bearingIfMoved(sixty, east, minMeters: 55661), isNull);
    });

    test('north and east both count towards the floor', () {
      // 3 and 4 hundredths of a metre-scale hypotenuse: 3-4-5.
      const a = LatLng(0, 0);
      final b = LatLng(3 / 111320, 4 / 111320);
      expect(bearingIfMoved(a, b, minMeters: 4.99), isNotNull);
      expect(bearingIfMoved(a, b, minMeters: 5.01), isNull);
    });

    test('the bearing is measured from a, not b', () {
      final forward = bearingIfMoved(origin, const LatLng(0.001, 0.002))!;
      final back = bearingIfMoved(const LatLng(0.001, 0.002), origin)!;
      expect(forward, closeTo(63.4349488229, 1e-6));
      expect((forward + 180) % 360, closeTo(back, 1e-6));
    });
  });

  group('lerpHeading', () {
    test('holds still when there is nothing to turn', () {
      expect(lerpHeading(90, 90, 0.5), 90);
    });

    test('crosses north the short way', () {
      // 350 -> 10 is a 20 degree turn through zero, not 340 back the long way.
      expect(lerpHeading(350, 10, 0.5), 360);
      expect(lerpHeading(10, 350, 0.5), 0);
    });

    test('turns the short way in both directions', () {
      expect(lerpHeading(0, 90, 0.5), 45);
      expect(lerpHeading(90, 0, 0.5), 45);
      expect(lerpHeading(0, 270, 0.5), -45);
    });

    test('lands exactly on the endpoints', () {
      expect(lerpHeading(350, 10, 0), 350);
      expect(lerpHeading(350, 10, 1), 370);
    });
  });
  group('lerpHeading precision', () {
    test('a full step lands on the target by the short way', () {
      expect(lerpHeading(0, 90, 1), 90);
      expect(lerpHeading(0, 45, 1), 45);
      expect(lerpHeading(90, 0, 1), 0);
      expect(lerpHeading(100, 280, 1), -80);
      expect(lerpHeading(0, 180, 1), -180);
      expect(lerpHeading(0, 181, 1), -179);
      expect(lerpHeading(0, 179, 1), 179);
      expect(lerpHeading(30, 200, 1), 200);
      expect(lerpHeading(200, 30, 1), 30);
      expect(lerpHeading(270, 10, 1), 370);
      expect(lerpHeading(180, 0, 1), 0);
      expect(lerpHeading(181, 0, 1), 360);
      expect(lerpHeading(359, 0, 1), 360);
    });

    test('a fractional step moves that share of the shortest turn', () {
      expect(lerpHeading(0, 100, 0.25), 25);
      expect(lerpHeading(0, 260, 0.5), -50);
      expect(lerpHeading(10, 350, 0.5), 0);
      expect(lerpHeading(20, 40, 0), 20);
    });
  });
}
