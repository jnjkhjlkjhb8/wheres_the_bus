import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:wheres_the_bus/data/models/bus_models.dart';
import 'package:wheres_the_bus/features/home/home_screen.dart';

BusStationMember _pole(double lat, double lon) => BusStationMember(
  stationId: 's',
  stationUid: 'u$lat$lon',
  stationName: 'S',
  lat: lat,
  lon: lon,
);

void main() {
  group('projectToScreen', () {
    test('places a point north-east of centre up and to the right', () {
      final at = projectToScreen(
        point: const LatLng(25.01, 121.02),
        center: const LatLng(25, 121),
        zoom: 16,
        viewport: const Size(400, 800),
        bottomPadding: 100,
      );
      expect(at.dx, closeTo(1132.0718191429505, 1e-6));
      expect(at.dy, closeTo(-164.213732064949, 1e-6));
    });

    test('places a point south-west of centre down and to the left', () {
      final at = projectToScreen(
        point: const LatLng(24.99, 120.98),
        center: const LatLng(25, 121),
        zoom: 17,
        viewport: const Size(390, 844),
        bottomPadding: 180,
      );
      expect(at.dx, closeTo(-1669.1436382859008, 1e-6));
      expect(at.dy, closeTo(1360.427464129898, 1e-6));
    });

    test('the centre lands mid-width and mid-band', () {
      final at = projectToScreen(
        point: const LatLng(25, 121),
        center: const LatLng(25, 121),
        zoom: 16,
        viewport: const Size(400, 800),
        bottomPadding: 100,
      );
      expect((at.dx, at.dy), (200, 350));
    });
  });

  group('isOffCentre', () {
    bool off(
      LatLng target, {
      Size size = const Size(400, 800),
      double bottom = 100,
    }) => isOffCentre(
      size: size,
      bottomPadding: bottom,
      camCenter: const LatLng(25, 121),
      zoom: 16,
      target: target,
    );

    test('north and east each count against a 190 m threshold', () {
      expect(off(const LatLng(25.0017, 121)), isFalse);
      expect(off(const LatLng(25.0018, 121)), isTrue);
      expect(off(const LatLng(25, 121.0018)), isFalse);
      expect(off(const LatLng(25, 121.0019)), isTrue);
      expect(off(const LatLng(24.9982, 121)), isTrue);
    });

    test('the two axes add up in quadrature', () {
      expect(off(const LatLng(25.0012, 121)), isFalse);
      expect(off(const LatLng(25, 121.0014)), isFalse);
      expect(off(const LatLng(25.0012, 121.0014)), isTrue);
    });

    test('the threshold follows the shorter side of the visible band', () {
      const short = Size(400, 500);
      expect(
        off(const LatLng(25.0008, 121), size: short, bottom: 300),
        isFalse,
      );
      expect(off(const LatLng(25.0009, 121), size: short, bottom: 300), isTrue);
    });
  });

  group('mapBottomPaddingFor', () {
    test('without a measured sheet it is 30 percent, clamped', () {
      expect(mapBottomPaddingFor(screen: const Size(400, 1000)), 280);
      expect(mapBottomPaddingFor(screen: const Size(400, 800)), 240);
      expect(mapBottomPaddingFor(screen: const Size(400, 400)), 180);
    });

    test('with a sheet it parks the logo a gap above the edge', () {
      expect(
        mapBottomPaddingFor(
          screen: const Size(400, 1000),
          sheetOffset: 200,
          sheetViewport: const Size(400, 1000),
        ),
        202,
      );
      expect(
        mapBottomPaddingFor(
          screen: const Size(400, 1000),
          sheetOffset: 800,
          sheetViewport: const Size(400, 1000),
        ),
        502,
      );
    });
  });

  group('membersFramed', () {
    bool framed(List<BusStationMember> members) => membersFramed(
      members: members,
      viewport: const Size(400, 800),
      bottomPadding: 100,
      center: const LatLng(25, 121),
      zoom: 16,
    );

    test('poles inside the 120 px margin are framed', () {
      expect(framed([_pole(25, 121.0015), _pole(25, 120.9985)]), isTrue);
      expect(framed([_pole(25.0044, 121), _pole(24.9956, 121)]), isTrue);
    });

    test('a pole past any edge un-frames the group', () {
      expect(framed([_pole(25, 121), _pole(25, 121.002)]), isFalse);
      expect(framed([_pole(25, 121), _pole(25, 120.998)]), isFalse);
      expect(framed([_pole(25, 121), _pole(25.0046, 121)]), isFalse);
      expect(framed([_pole(25, 121), _pole(24.9954, 121)]), isFalse);
    });

    test('the frame edges themselves are inside', () {
      expect(outsideMemberFrame(const Offset(120, 120), 280, 580), isFalse);
      expect(outsideMemberFrame(const Offset(280, 580), 280, 580), isFalse);
      expect(outsideMemberFrame(const Offset(119.9, 300), 280, 580), isTrue);
      expect(outsideMemberFrame(const Offset(280.1, 300), 280, 580), isTrue);
      expect(outsideMemberFrame(const Offset(200, 119.9), 280, 580), isTrue);
      expect(outsideMemberFrame(const Offset(200, 580.1), 280, 580), isTrue);
    });
  });

  group('member bounds', () {
    test('the box spans every pole whatever their order', () {
      final bounds = memberBoundsOf([
        _pole(25.0, 121.5),
        _pole(24.5, 121.0),
        _pole(25.5, 120.5),
        _pole(24.8, 122.0),
      ]);
      expect(bounds.southwest, const LatLng(24.5, 120.5));
      expect(bounds.northeast, const LatLng(25.5, 122.0));
    });

    test('a box under a micro-degree on both sides is collapsed', () {
      LatLngBounds box(double lat, double lon) => LatLngBounds(
        southwest: const LatLng(25, 121),
        northeast: LatLng(25 + lat, 121 + lon),
      );
      expect(boundsCollapsed(box(5e-7, 5e-7)), isTrue);
      expect(boundsCollapsed(box(5e-7, 2e-6)), isFalse);
      expect(boundsCollapsed(box(2e-6, 5e-7)), isFalse);
      expect(boundsCollapsed(box(2e-6, 2e-6)), isFalse);
    });

    test('the centre is the midpoint of each axis', () {
      final centre = boundsCenter(
        LatLngBounds(
          southwest: const LatLng(24.0, 120.0),
          northeast: const LatLng(26.0, 124.0),
        ),
      );
      expect(centre, const LatLng(25.0, 122.0));
    });
  });
}
