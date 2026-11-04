import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:google_maps_flutter_platform_interface/google_maps_flutter_platform_interface.dart';
import 'package:wheres_the_bus/shared/map/motion_aware_camera.dart';

import '../../support/fakes/map_platform.dart';

void main() {
  late FakeMapPlatform maps;
  late GoogleMapController controller;

  setUp(() {
    maps = FakeMapPlatform();
    GoogleMapsFlutterPlatform.instance = maps;
  });

  Future<void> pumpMap(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: GoogleMap(
          initialCameraPosition: const CameraPosition(target: LatLng(25, 121)),
          onMapCreated: (c) => controller = c,
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('reduced snaps with moveCamera', (tester) async {
    await pumpMap(tester);
    final update = CameraUpdate.newLatLng(const LatLng(1, 2));

    await controller.moveOrAnimate(update, reduced: true);

    expect(maps.movedUpdates, [update]);
    expect(maps.animatedUpdates, isEmpty);
  });

  testWidgets('not reduced still animates', (tester) async {
    await pumpMap(tester);
    final update = CameraUpdate.newLatLng(const LatLng(1, 2));

    await controller.moveOrAnimate(update, reduced: false);

    expect(maps.animatedUpdates, [update]);
    expect(maps.movedUpdates, isEmpty);
  });
}
