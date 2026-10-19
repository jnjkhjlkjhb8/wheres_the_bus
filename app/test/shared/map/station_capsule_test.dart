import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:wheres_the_bus/shared/map/marker_factory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => MapMarkers.configure(devicePixelRatio: 3));

  Future<ui.Size> dimensions(BitmapDescriptor descriptor) async {
    final codec = await ui.instantiateImageCodec(
      (descriptor as BytesMapBitmap).byteData,
    );
    final image = (await codec.getNextFrame()).image;
    final size = ui.Size(image.width.toDouble(), image.height.toDouble());
    image.dispose();
    codec.dispose();
    return size;
  }

  test(
    'station names flip around the same plate and selection changes the ink',
    () async {
      for (final selected in [false, true]) {
        final right = await MapMarkers.stationCapsule(
          asset: 'assets/marker/Bus.svg',
          label: '忠孝復興站',
          selected: selected,
          flip: false,
        );
        final left = await MapMarkers.stationCapsule(
          asset: 'assets/marker/Bus.svg',
          label: '忠孝復興站',
          selected: selected,
          flip: true,
        );
        expect(right.anchor.dx, lessThan(0.5));
        expect(left.anchor.dx, closeTo(1 - right.anchor.dx, 0.01));
        expect(left.anchor.dy, 0.5);
        expect(await dimensions(left.icon), await dimensions(right.icon));
        expect(
          identical(
            right,
            await MapMarkers.stationCapsule(
              asset: 'assets/marker/Bus.svg',
              label: '忠孝復興站',
              selected: selected,
              flip: false,
            ),
          ),
          isTrue,
        );
      }
      final plain = await MapMarkers.stationCapsule(
        asset: 'assets/marker/Bus.svg',
        label: '忠孝復興站',
        selected: false,
        flip: false,
      );
      final selected = await MapMarkers.stationCapsule(
        asset: 'assets/marker/Bus.svg',
        label: '忠孝復興站',
        selected: true,
        flip: false,
      );
      expect(
        (plain.icon as BytesMapBitmap).byteData,
        isNot((selected.icon as BytesMapBitmap).byteData),
      );
    },
  );

  test('dot rings preserve the same marker dimensions', () async {
    final plain = await MapMarkers.dot(Colors.black);
    final ringed = await MapMarkers.dot(Colors.black, ring: Colors.white);
    expect(await dimensions(plain), const ui.Size(54, 54));
    expect(await dimensions(ringed), const ui.Size(54, 54));
    expect(
      (plain as BytesMapBitmap).byteData,
      isNot((ringed as BytesMapBitmap).byteData),
    );
  });
}
