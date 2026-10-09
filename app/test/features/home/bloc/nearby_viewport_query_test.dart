import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:wheres_the_bus/features/home/bloc/nearby_viewport_query.dart';

void main() {
  group('nearbyRadiusForViewport', () {
    test('derives the radius from center to the farthest corner', () {
      const center = LatLng(25.0330, 121.5654);
      // ~0.01 degrees latitude ≈ 1.1 km; northeast is the farthest corner.
      final bounds = LatLngBounds(
        southwest: const LatLng(25.0230, 121.5554),
        northeast: const LatLng(25.0430, 121.5754),
      );

      final radius = nearbyRadiusForViewport(center: center, bounds: bounds);

      final expected = haversineMeters(center, bounds.northeast);
      expect(radius, closeTo(expected, 1));
    });

    test('clamps to the backend max radius for a large viewport', () {
      const center = LatLng(25.0330, 121.5654);
      final bounds = LatLngBounds(
        southwest: const LatLng(24, 120.5),
        northeast: const LatLng(26, 122.5),
      );

      final radius = nearbyRadiusForViewport(center: center, bounds: bounds);

      expect(radius, kNearbyMaxRadiusMeters);
    });

    test('clamps to the minimum radius for a near-zero viewport', () {
      const center = LatLng(25.0330, 121.5654);
      final bounds = LatLngBounds(
        southwest: const LatLng(25.033000001, 121.565400001),
        northeast: const LatLng(25.033000002, 121.565400002),
      );

      final radius = nearbyRadiusForViewport(center: center, bounds: bounds);

      expect(radius, kNearbyMinRadiusMeters);
    });
  });

  group('haversineMeters', () {
    test('is zero for identical points', () {
      const p = LatLng(25.0330, 121.5654);
      expect(haversineMeters(p, p), 0);
    });

    test('one degree of latitude is about 111 km', () {
      const a = LatLng(25, 121);
      const b = LatLng(26, 121);
      final meters = haversineMeters(a, b);
      expect(meters, closeTo(111195, 500));
    });
  });

  group('NearbyViewportQuery', () {
    const center = LatLng(25.0330, 121.5654);
    const nearby = LatLng(25.0331, 121.5655); // well under 200 m away
    const far = LatLng(25.1330, 121.6654); // well over 200 m away
    const radius = 670;

    /// A completed query covering [center] out to [radius].
    NearbyViewportQuery covered() =>
        const NearbyViewportQuery().withAttempted(center, radius).withSuccess();

    test('always queries when nothing has been covered yet', () {
      const query = NearbyViewportQuery();
      expect(query.shouldQuery(center, radius), isTrue);
    });

    test('suppresses a query near the last successful center', () {
      expect(covered().shouldQuery(nearby, radius), isFalse);
    });

    test('still queries when far from the last successful center', () {
      expect(covered().shouldQuery(far, radius), isTrue);
    });

    test('suppresses a slightly wider viewport at the same center', () {
      expect(covered().shouldQuery(center, 800), isFalse);
    });

    test('queries again when zooming out widens the radius materially', () {
      // Same centre, so distance alone would suppress this; the grown radius
      // reaches stations the covered query never asked for.
      expect(covered().shouldQuery(center, 2000), isTrue);
    });

    test('suppresses while a query for the same viewport is in flight', () {
      final inFlight = const NearbyViewportQuery().withAttempted(
        center,
        radius,
      );
      expect(inFlight.shouldQuery(nearby, radius), isFalse);
    });

    test(
      'a failed attempt does not suppress a retry at the same center — only '
      'a successful one does',
      () {
        final afterFailure = const NearbyViewportQuery()
            .withAttempted(center, radius)
            .withFailure();

        expect(afterFailure.inFlight, isNull);
        expect(afterFailure.shouldQuery(center, radius), isTrue);
      },
    );

    test('success promotes the in-flight query and clears the slot', () {
      final query = const NearbyViewportQuery()
          .withAttempted(center, radius)
          .withSuccess();

      expect(query.inFlight, isNull);
      expect(query.lastSuccessful?.center, center);
      expect(query.lastSuccessful?.radiusMeters, radius);
    });

    test('a response with nothing in flight leaves the coverage alone', () {
      final query = covered().withSuccess();
      expect(query.lastSuccessful?.center, center);
    });
  });

  group('screenPixelsForMeters', () {
    test('projects a radius at the zoom the map is actually showing', () {
      // Taipei at zoom 15: ~4.33 m per logical pixel, so a 1 km search
      // reaches a little over 230 px — about half a phone's width.
      final px = screenPixelsForMeters(
        meters: 1000,
        latitude: 25.0330,
        zoom: 15,
      );
      expect(px, closeTo(231, 1));
    });

    test('one zoom level in doubles the pixels the same radius covers', () {
      final out = screenPixelsForMeters(
        meters: 800,
        latitude: 25.0330,
        zoom: 14,
      );
      final zoomedIn = screenPixelsForMeters(
        meters: 800,
        latitude: 25.0330,
        zoom: 15,
      );
      expect(zoomedIn, closeTo(out * 2, 0.001));
    });

    test('the same radius covers more pixels away from the equator', () {
      final taipei = screenPixelsForMeters(
        meters: 1000,
        latitude: 25.0330,
        zoom: 15,
      );
      final equator = screenPixelsForMeters(
        meters: 1000,
        latitude: 0,
        zoom: 15,
      );
      expect(taipei, greaterThan(equator));
    });
  });
}
