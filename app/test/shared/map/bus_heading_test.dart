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
}
