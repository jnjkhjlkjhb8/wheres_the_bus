import 'package:flutter/rendering.dart' show Size;
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:wheres_the_bus/features/home/bloc/nearby_viewport_query.dart';

void main() {
  group('haversineMeters', () {
    test('matches reference great-circle distances', () {
      expect(
        haversineMeters(const LatLng(0, 0), const LatLng(0, 1)),
        closeTo(111194.927, 0.5),
      );
      expect(
        haversineMeters(const LatLng(60, 0), const LatLng(60, 1)),
        closeTo(55596.934, 0.5),
      );
      expect(
        haversineMeters(const LatLng(25, 121), const LatLng(26, 122)),
        closeTo(149788.340, 0.5),
      );
      expect(
        haversineMeters(
          const LatLng(-33.87, 151.21),
          const LatLng(51.5, -0.12),
        ),
        closeTo(16994008.112, 1),
      );
      expect(
        haversineMeters(
          const LatLng(25.033, 121.5654),
          const LatLng(25.0478, 121.517),
        ),
        closeTo(5146.221, 0.5),
      );
    });

    test('is symmetric', () {
      const a = LatLng(25.033, 121.5654);
      const b = LatLng(-12.5, 40.25);
      expect(haversineMeters(a, b), closeTo(haversineMeters(b, a), 1e-6));
    });
  });

  group('metersPerPixel', () {
    test('matches the Web Mercator ground resolution', () {
      expect(metersPerPixel(0, 0), closeTo(156543.03392, 1e-6));
      expect(metersPerPixel(60, 0), closeTo(78271.51696, 1e-5));
      expect(metersPerPixel(25, 15), closeTo(4.329717, 1e-5));
      expect(metersPerPixel(0, 10), closeTo(152.874057, 1e-5));
    });
  });

  group('nearbyRadiusForViewport', () {
    final bounds = LatLngBounds(
      southwest: const LatLng(25.02, 121.55),
      northeast: const LatLng(25.03, 121.57),
    );
    const southwest = LatLng(25.02, 121.55);
    const northeast = LatLng(25.03, 121.57);
    const northwest = LatLng(25.03, 121.55);
    const southeast = LatLng(25.02, 121.57);

    // A centre sitting on one corner makes the opposite corner the farthest,
    // so each case pins down one corner of the box.
    for (final (name, center, farCorner) in const [
      ('northeast', northeast, southwest),
      ('southwest', southwest, northeast),
      ('northwest', northwest, southeast),
      ('southeast', southeast, northwest),
    ]) {
      test('reaches the opposite corner from the $name corner', () {
        expect(
          nearbyRadiusForViewport(center: center, bounds: bounds),
          haversineMeters(center, farCorner).round(),
        );
      });
    }

    test('rounds to the nearest whole metre', () {
      int radiusEast(double degrees) => nearbyRadiusForViewport(
        center: const LatLng(25.0, 121.5),
        bounds: LatLngBounds(
          southwest: const LatLng(25.0, 121.5),
          northeast: LatLng(25.0, 121.5 + degrees),
        ),
      );
      // 1239.55 m and 1235.32 m: neither floor nor ceil agrees with both.
      expect(radiusEast(0.0123), 1240);
      expect(radiusEast(0.012258), 1235);
    });

    test('a viewport smaller than the floor still asks for 100 metres', () {
      final tight = LatLngBounds(
        southwest: const LatLng(25.0, 121.5),
        northeast: const LatLng(25.0, 121.5001),
      );
      expect(
        nearbyRadiusForViewport(
          center: const LatLng(25.0, 121.5),
          bounds: tight,
        ),
        kNearbyMinRadiusMeters,
      );
    });

    test('is capped at the backend limit and floored at the minimum', () {
      expect(kNearbyMaxRadiusMeters, 5000);
      expect(kNearbyMinRadiusMeters, 100);
      expect(
        nearbyRadiusForViewport(
          center: const LatLng(25, 121),
          bounds: LatLngBounds(
            southwest: const LatLng(20, 115),
            northeast: const LatLng(30, 125),
          ),
        ),
        5000,
      );
    });
  });

  group('estimatedNearbyRadius', () {
    test('spans the farthest bottom corner of the padded viewport', () {
      expect(
        estimatedNearbyRadius(
          size: const Size(400, 800),
          bottomPadding: 200,
          center: const LatLng(25, 121),
          zoom: 15,
        ),
        2332,
      );
      expect(
        estimatedNearbyRadius(
          size: const Size(400, 800),
          bottomPadding: 0,
          center: const LatLng(25, 121),
          zoom: 15,
        ),
        1936,
      );
      expect(
        estimatedNearbyRadius(
          size: const Size(300, 500),
          bottomPadding: 100,
          center: const LatLng(60, 121),
          zoom: 14,
        ),
        1602,
      );
      expect(
        estimatedNearbyRadius(
          size: const Size(360, 640),
          bottomPadding: 120,
          center: const LatLng(25.033, 121.5654),
          zoom: 16,
        ),
        910,
      );
    });

    test('clamps to the backend range', () {
      expect(
        estimatedNearbyRadius(
          size: Size.zero,
          bottomPadding: 0,
          center: const LatLng(25, 121),
          zoom: 15,
        ),
        kNearbyMinRadiusMeters,
      );
      expect(
        estimatedNearbyRadius(
          size: const Size(1000, 2000),
          bottomPadding: 500,
          center: const LatLng(25, 121),
          zoom: 5,
        ),
        kNearbyMaxRadiusMeters,
      );
    });
  });

  group('NearbyCoverage.covers', () {
    const origin = LatLng(25.033, 121.5654);
    const coverage = NearbyCoverage(origin, 100);
    const other = LatLng(25.034, 121.5654);

    test('the distance threshold is exclusive', () {
      final distance = haversineMeters(other, origin);
      expect(coverage.covers(other, 100, distance + 0.001), isTrue);
      expect(coverage.covers(other, 100, distance), isFalse);
      expect(coverage.covers(other, 100, distance - 0.001), isFalse);
    });

    test('a radius up to 20% larger still counts as covered', () {
      expect(coverage.covers(origin, 120, 200), isTrue);
      expect(coverage.covers(origin, 121, 200), isFalse);
      expect(coverage.covers(origin, 80, 200), isTrue);
    });

    test('keeps the centre and radius it was built with', () {
      expect(coverage.center, origin);
      expect(coverage.radiusMeters, 100);
    });
  });

  group('NearbyViewportQuery.shouldQuery', () {
    const origin = LatLng(25.033, 121.5654);
    // One degree of latitude is 111194.9 m, so these are 190 m and 210 m
    // north of [origin].
    final within = LatLng(
      origin.latitude + 190 / 111194.9266,
      origin.longitude,
    );
    final beyond = LatLng(
      origin.latitude + 210 / 111194.9266,
      origin.longitude,
    );

    test('the default threshold is 200 metres', () {
      final query = const NearbyViewportQuery().withAttempted(origin, 500);
      expect(query.shouldQuery(within, 500), isFalse);
      expect(query.shouldQuery(beyond, 500), isTrue);
    });

    test('an explicit threshold overrides the default', () {
      final query = const NearbyViewportQuery().withAttempted(origin, 500);
      expect(query.shouldQuery(beyond, 500, thresholdMeters: 250), isFalse);
      expect(query.shouldQuery(within, 500, thresholdMeters: 150), isTrue);
    });

    test('either slot covering the viewport suppresses the query', () {
      final onlyInFlight = const NearbyViewportQuery().withAttempted(
        origin,
        500,
      );
      expect(onlyInFlight.lastSuccessful, isNull);
      expect(onlyInFlight.shouldQuery(origin, 500), isFalse);

      final onlySettled = onlyInFlight.withSuccess();
      expect(onlySettled.inFlight, isNull);
      expect(onlySettled.shouldQuery(origin, 500), isFalse);

      final moved = onlySettled.withAttempted(beyond, 500);
      expect(moved.shouldQuery(origin, 500), isFalse);
      expect(moved.shouldQuery(beyond, 500), isFalse);
      expect(
        moved.shouldQuery(
          LatLng(origin.latitude + 1, origin.longitude),
          500,
        ),
        isTrue,
      );
    });
  });

  group('NearbyViewportQuery transitions', () {
    const a = LatLng(25.033, 121.5654);
    const b = LatLng(25.1, 121.6);

    test('attempting keeps the last successful coverage', () {
      final settled = const NearbyViewportQuery()
          .withAttempted(a, 300)
          .withSuccess();
      final next = settled.withAttempted(b, 700);
      expect(next.inFlight?.center, b);
      expect(next.inFlight?.radiusMeters, 700);
      expect(next.lastSuccessful?.center, a);
      expect(next.lastSuccessful?.radiusMeters, 300);
    });

    test('failure drops the in-flight query and keeps the settled one', () {
      final settled = const NearbyViewportQuery()
          .withAttempted(a, 300)
          .withSuccess();
      final failed = settled.withAttempted(b, 700).withFailure();
      expect(failed.inFlight, isNull);
      expect(failed.lastSuccessful?.center, a);
      expect(failed.lastSuccessful?.radiusMeters, 300);
    });

    test('success with nothing in flight keeps the settled coverage', () {
      final settled = const NearbyViewportQuery()
          .withAttempted(a, 300)
          .withSuccess();
      final again = settled.withSuccess();
      expect(again.lastSuccessful?.center, a);
      expect(again.inFlight, isNull);
      expect(const NearbyViewportQuery().withSuccess().lastSuccessful, isNull);
    });

    test('success replaces the settled coverage with the in-flight one', () {
      final next = const NearbyViewportQuery()
          .withAttempted(a, 300)
          .withSuccess()
          .withAttempted(b, 700)
          .withSuccess();
      expect(next.lastSuccessful?.center, b);
      expect(next.lastSuccessful?.radiusMeters, 700);
      expect(next.inFlight, isNull);
    });
  });
}
