import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:wheres_the_bus/shared/map/marker_factory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const kLabel = '忠孝復興站';

  // configure() is process-global; leaving a scale set would silently resize
  // every later test's bitmaps.
  setUp(
    () => MapMarkers.configure(
      devicePixelRatio: 3,
    ),
  );

  Future<({BitmapDescriptor icon, Offset anchor})> build({
    Color fill = Colors.white,
    Color content = Colors.black,
    Color? ring = Colors.black,
    double ringWidth = 2,
    double height = 32,
    String? text = '5',
    IconData? glyph,
    bool pill = false,
    String? label,
    Color labelFill = Colors.black,
    Color labelInk = Colors.white,
    bool flip = false,
  }) => MapMarkers.stopMarker(
    fill: fill,
    content: content,
    ring: ring,
    ringWidth: ringWidth,
    height: height,
    text: text,
    glyph: glyph,
    pill: pill,
    label: label,
    labelFill: labelFill,
    labelInk: labelInk,
    flip: flip,
  );

  group('anchor', () {
    test('a bare plate pins by its centre despite the shadow margin', () async {
      final bare = await build();
      expect(bare.anchor.dx, closeTo(0.5, 0.001));
      expect(bare.anchor.dy, 0.5);
    });

    test('a capsule pins by its plate, not the bitmap centre', () async {
      final capsule = await build(label: kLabel);
      // The label hangs off one side, so the plate sits left of centre.
      expect(capsule.anchor.dx, lessThan(0.5));
      expect(capsule.anchor.dy, 0.5);
    });

    test('flipping mirrors the anchor about the bitmap centre', () async {
      final right = await build(label: kLabel);
      final left = await build(label: kLabel, flip: true);
      // Same bitmap width either way, so the two anchors must be reflections;
      // the tolerance is the one pixel the width rounds up by.
      expect(left.anchor.dx, closeTo(1 - right.anchor.dx, 0.01));
    });

    test('a pill plate still pins by the pill, so it stays centred', () async {
      final word = await build(text: '進站中', pill: true, ring: null);
      expect(word.anchor.dx, closeTo(0.5, 0.001));
    });
  });

  group('text scale', () {
    /// The bitmap's real pixel size, which is the only honest evidence that the
    /// plate grew with the text rather than the text overflowing a fixed plate.
    Future<ui.Size> sizeOf(BitmapDescriptor descriptor) async {
      final codec = await ui.instantiateImageCodec(
        (descriptor as BytesMapBitmap).byteData,
      );
      final image = (await codec.getNextFrame()).image;
      final size = ui.Size(image.width.toDouble(), image.height.toDouble());
      image.dispose();
      return size;
    }

    Future<ui.Size> sizeAt(double factor) async {
      MapMarkers.configure(
        devicePixelRatio: 3,
        textScaler: TextScaler.linear(factor),
      );
      return sizeOf((await build(label: kLabel)).icon);
    }

    test('the whole marker grows with the text setting', () async {
      final base = await sizeAt(1);
      final bigger = await sizeAt(1.2);
      expect(bigger.height / base.height, closeTo(1.2, 0.02));
      expect(bigger.width / base.width, closeTo(1.2, 0.02));
    });

    test('growth stops at the documented 1.3x ceiling', () async {
      final capped = await sizeAt(1.3);
      // 2.0x would make a 60-stop route unreadable; the clamp is the whole
      // reason marker type is not simply handed the raw scaler.
      expect(await sizeAt(2), capped);
      expect(await sizeAt(3), capped);
    });

    test('a smaller text setting never shrinks the designed size', () async {
      final base = await sizeAt(1);
      expect(await sizeAt(0.8), base);
    });

    test('scale reaches the cache key, so bitmaps are not reused', () async {
      MapMarkers.configure(
        devicePixelRatio: 3,
      );
      final plain = (await build()).icon;
      MapMarkers.configure(
        devicePixelRatio: 3,
        textScaler: const TextScaler.linear(1.2),
      );
      expect((await build()).icon, isNot(same(plain)));
    });
  });

  group('cache capacity', () {
    test('one frame of the longest route does not evict itself', () async {
      final first = (await build(text: '1')).icon;
      for (var stop = 2; stop <= 60; stop++) {
        await build(text: '$stop');
      }
      await build(text: '30', label: kLabel);
      for (var vehicle = 0; vehicle < 5; vehicle++) {
        await MapMarkers.busBubble(
          plate: 'KKA-000$vehicle',
          fill: Colors.white,
          inkSecondary: Colors.grey,
          statusLabel: '正常',
          statusColor: Colors.black,
          gpsText: '3 秒前',
        );
      }
      expect(
        (await build(text: '1')).icon,
        same(first),
        reason: 'a 60-stop frame plus its vehicles overflowed the LRU cap',
      );
    });
  });

  group('cache key', () {
    test('identical inputs reuse the same bitmap', () async {
      expect((await build()).icon, same((await build()).icon));
    });

    test('every plate input discriminates the cache entry', () async {
      final base = (await build()).icon;
      final variants = {
        'fill': build(fill: Colors.green),
        'content': build(content: Colors.white),
        'ring': build(ring: null),
        'ringWidth': build(ringWidth: 3),
        'height': build(height: 34),
        'text': build(text: '6'),
        'glyph': build(text: null, glyph: Icons.close_rounded),
        'pill': build(text: '進站中', pill: true),
        'label': build(label: kLabel),
      };
      for (final entry in variants.entries) {
        expect(
          (await entry.value).icon,
          isNot(same(base)),
          reason: '${entry.key} is not part of the cache key',
        );
      }
    });

    test('every label input discriminates the cache entry', () async {
      final base = (await build(label: kLabel)).icon;
      final variants = {
        'label': build(label: '臺北車站'),
        'labelFill': build(label: kLabel, labelFill: Colors.grey),
        'labelInk': build(label: kLabel, labelInk: Colors.grey),
        'flip': build(label: kLabel, flip: true),
      };
      for (final entry in variants.entries) {
        expect(
          (await entry.value).icon,
          isNot(same(base)),
          reason: '${entry.key} is not part of the cache key',
        );
      }
    });
  });
}
