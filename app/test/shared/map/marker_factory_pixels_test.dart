import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:wheres_the_bus/shared/map/marker_factory.dart';

import 'marker_factory_pixels_expected.dart';

/// Marker bitmaps are raster output, so what pins their geometry is the pixels
/// themselves: each case renders one marker and compares a coarse grid of its
/// alpha-weighted colour against a recorded signature. The grid tolerates
/// anti-aliasing differences between rasterisers; a moved or resized shape
/// still shifts whole cells. Re-record after an intended visual change with
/// `--dart-define=RECORD=true`.
const _record = bool.fromEnvironment('RECORD');

const _gridSize = 6;
const _tolerance = 4;

/// `<width>x<height>:` followed by, per grid cell, the mean alpha and the
/// alpha-weighted mean red, green and blue as two hex digits each.
Future<String> _signature(BitmapDescriptor descriptor) async {
  final codec = await ui.instantiateImageCodec(
    (descriptor as BytesMapBitmap).byteData,
  );
  final image = (await codec.getNextFrame()).image;
  final bytes = (await image.toByteData())!.buffer.asUint8List();
  final width = image.width;
  final height = image.height;
  final sums = List.filled(_gridSize * _gridSize * 4, 0);
  final counts = List.filled(_gridSize * _gridSize, 0);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final cell = y * _gridSize ~/ height * _gridSize + x * _gridSize ~/ width;
      final at = (y * width + x) * 4;
      final alpha = bytes[at + 3];
      counts[cell]++;
      sums[cell * 4] += alpha;
      for (var channel = 0; channel < 3; channel++) {
        sums[cell * 4 + 1 + channel] += bytes[at + channel] * alpha ~/ 255;
      }
    }
  }
  final hex = StringBuffer('${width}x$height:');
  for (var i = 0; i < sums.length; i++) {
    final mean = counts[i ~/ 4] == 0 ? 0 : sums[i] ~/ counts[i ~/ 4];
    hex.write(mean.toRadixString(16).padLeft(2, '0'));
  }
  image.dispose();
  codec.dispose();
  return hex.toString();
}

void _expectSignature(String name, String actual) {
  final expected = markerSignatures[name];
  expect(expected, isNotNull, reason: '$name has no recorded signature');
  final [expectedSize, expectedCells] = expected!.split(':');
  final [actualSize, actualCells] = actual.split(':');
  expect(actualSize, expectedSize, reason: '$name size');
  for (var i = 0; i < expectedCells.length; i += 2) {
    final want = int.parse(expectedCells.substring(i, i + 2), radix: 16);
    final got = int.parse(actualCells.substring(i, i + 2), radix: 16);
    expect(
      (got - want).abs(),
      lessThanOrEqualTo(_tolerance),
      reason: '$name cell ${i ~/ 8} channel ${i ~/ 2 % 4}',
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final seen = <String, String>{};

  setUp(() => MapMarkers.configure(devicePixelRatio: 3));
  tearDownAll(() {
    if (_record) {
      final entries = seen.entries.map((e) => "'${e.key}': '${e.value}'");
      // The only way to read the recorded values out of a `flutter test` run.
      // ignore: avoid_print
      print('RECORDED {${entries.join(', ')}}');
    }
  });

  Future<void> check(String name, Future<BitmapDescriptor> pending) async {
    final actual = await _signature(await pending);
    seen[name] = actual;
    if (!_record) _expectSignature(name, actual);
  }

  Future<void> checkIcon(
    String name,
    Future<({BitmapDescriptor icon, Offset anchor})> pending,
  ) async {
    final marker = await pending;
    final actual = await _signature(marker.icon);
    seen[name] = actual;
    seen['$name/anchor'] = marker.anchor.dx.toStringAsFixed(6);
    if (!_record) {
      _expectSignature(name, actual);
      expect(seen['$name/anchor'], markerAnchors['$name/anchor'], reason: name);
    }
  }

  const ink = Color(0xFF111111);
  const paper = Color(0xFFFFFFFF);
  const accent = Color(0xFF2E7D32);
  const amber = Color(0xFFFFB300);

  group('bus mark', () {
    test('plain, ringed, headless, shadowless and large', () async {
      await check(
        'busmark/plain',
        MapMarkers.busMark(body: ink, halo: paper),
      );
      await check(
        'busmark/ring',
        MapMarkers.busMark(body: ink, halo: paper, ring: amber),
      );
      await check(
        'busmark/headless',
        MapMarkers.busMark(body: accent, halo: paper, showHeading: false),
      );
      await check(
        'busmark/flat',
        MapMarkers.busMark(body: ink, halo: paper, shadow: false),
      );
      await check(
        'busmark/large',
        MapMarkers.busMark(body: ink, halo: paper, size: 40),
      );
    });
  });

  group('bus bubble', () {
    test('status, plate and clock lines with optional glyph', () async {
      await check(
        'bubble/plain',
        MapMarkers.busBubble(
          plate: 'ABC-123',
          fill: paper,
          inkSecondary: ink,
          statusLabel: '營運中',
          statusColor: accent,
          gpsText: '5秒前',
        ),
      );
      await check(
        'bubble/glyph',
        MapMarkers.busBubble(
          plate: 'ABC-123',
          fill: paper,
          inkSecondary: ink,
          statusLabel: '故障',
          statusColor: amber,
          gpsText: '1分前',
          trackGlyph: '✓',
        ),
      );
      await check(
        'bubble/clear',
        MapMarkers.busBubble(
          plate: 'KAA-9999',
          fill: ink,
          inkSecondary: paper,
          statusLabel: '營運中',
          statusColor: accent,
          gpsText: '定位延遲',
          clearance: 40,
        ),
      );
    });
  });

  group('stop marker', () {
    test('countdown, long, glyph, pill, capsule and flip', () async {
      await checkIcon(
        'stop/digit',
        MapMarkers.stopMarker(
          fill: paper,
          content: ink,
          ring: ink,
          text: '5',
        ),
      );
      await checkIcon(
        'stop/three',
        MapMarkers.stopMarker(
          fill: paper,
          content: ink,
          ring: ink,
          text: '123',
        ),
      );
      await checkIcon(
        'stop/glyph',
        MapMarkers.stopMarker(
          fill: paper,
          content: ink,
          ring: ink,
          ringWidth: 1.5,
          height: 30,
          glyph: Icons.close_rounded,
        ),
      );
      await checkIcon(
        'stop/pill',
        MapMarkers.stopMarker(
          fill: accent,
          content: paper,
          text: '進站中',
          pill: true,
        ),
      );
      await checkIcon(
        'stop/thick',
        MapMarkers.stopMarker(
          fill: paper,
          content: ink,
          ring: amber,
          ringWidth: 3,
          height: 34,
          text: '2',
        ),
      );
      await checkIcon(
        'stop/capsule',
        MapMarkers.stopMarker(
          fill: paper,
          content: ink,
          ring: ink,
          text: '5',
          label: '忠孝復興站',
        ),
      );
      await checkIcon(
        'stop/flipped',
        MapMarkers.stopMarker(
          fill: paper,
          content: ink,
          ring: ink,
          text: '5',
          label: '忠孝復興站',
          flip: true,
          labelFill: accent,
        ),
      );
      await checkIcon(
        'stop/longlabel',
        MapMarkers.stopMarker(
          fill: paper,
          content: ink,
          text: '7',
          label: '非常非常非常非常非常非常非常非常非常非常非常非常長的站名',
        ),
      );
    });

    test('bitmaps follow the device ratio and text scale', () async {
      MapMarkers.configure(devicePixelRatio: 2);
      await checkIcon(
        'stop/dpr2',
        MapMarkers.stopMarker(fill: paper, content: ink, text: '5'),
      );
      MapMarkers.configure(
        devicePixelRatio: 2,
        textScaler: const TextScaler.linear(1.2),
      );
      await checkIcon(
        'stop/scale12',
        MapMarkers.stopMarker(fill: paper, content: ink, text: '5'),
      );
      MapMarkers.configure(
        devicePixelRatio: 2,
        textScaler: const TextScaler.linear(3),
      );
      await checkIcon(
        'stop/scaleCapped',
        MapMarkers.stopMarker(fill: paper, content: ink, text: '5'),
      );
      MapMarkers.configure(
        devicePixelRatio: 2,
        textScaler: const TextScaler.linear(0.5),
      );
      await checkIcon(
        'stop/scaleFloor',
        MapMarkers.stopMarker(fill: paper, content: ink, text: '5'),
      );
      MapMarkers.configure(devicePixelRatio: 0);
      await checkIcon(
        'stop/dprKept',
        MapMarkers.stopMarker(fill: paper, content: ink, text: '5'),
      );
      MapMarkers.configure(devicePixelRatio: 3);
    });
  });

  group('station capsule', () {
    test('selection, flip, ground and size', () async {
      for (final selected in [false, true]) {
        for (final flip in [false, true]) {
          await checkIcon(
            'cap/$selected/$flip',
            MapMarkers.stationCapsule(
              asset: 'assets/marker/Bus.svg',
              label: '忠孝復興站',
              selected: selected,
              flip: flip,
            ),
          );
        }
      }
      await checkIcon(
        'cap/ground',
        MapMarkers.stationCapsule(
          asset: 'assets/marker/bike.svg',
          label: '捷運站',
          selected: false,
          flip: false,
          plateGround: amber,
          size: 40,
        ),
      );
    });
  });

  group('dots and arrows', () {
    test('dot, ringed dot, target dot, nav arrow and svg', () async {
      await check('dot/plain', MapMarkers.dot(accent));
      await check('dot/ring', MapMarkers.dot(accent, ring: paper, size: 24));
      await check('target', MapMarkers.targetDot(accent, paper));
      await check('target/small', MapMarkers.targetDot(ink, amber, size: 14));
      await check('nav', MapMarkers.navArrow(accent, paper));
      await check('nav/small', MapMarkers.navArrow(ink, amber, size: 30));
      await check('svg', MapMarkers.svgAsset('assets/marker/bike.svg'));
      await check(
        'svg/small',
        MapMarkers.svgAsset('assets/marker/Bus.svg', size: 20),
      );
    });
  });

  group('memoisation', () {
    test('equal requests share one bitmap', () async {
      final first = await MapMarkers.dot(accent, size: 11);
      final second = await MapMarkers.dot(accent, size: 11);
      expect(identical(first, second), isTrue);
    });

    test('bubbles keep the sixteen most recent', () async {
      Future<BitmapDescriptor> bubble(int i) => MapMarkers.busBubble(
        plate: 'P$i',
        fill: paper,
        inkSecondary: ink,
        statusLabel: 'ok',
        statusColor: accent,
        gpsText: '$i',
      );
      final held = [for (var i = 0; i < 16; i++) await bubble(i)];
      // Sixteen distinct bubbles fit exactly, so all of them are still shared.
      for (var i = 0; i < 16; i++) {
        expect(identical(await bubble(i), held[i]), isTrue, reason: '$i');
      }
      // A seventeenth pushes out the least recently used one, which is 0.
      await bubble(16);
      expect(identical(await bubble(0), held[0]), isFalse);
    });

    test('the general cache holds 256 entries', () async {
      Future<BitmapDescriptor> dot(int i) =>
          MapMarkers.dot(ink, size: 3 + i / 1000);
      // Flush whatever earlier tests left behind.
      for (var i = 1000; i < 1300; i++) {
        await dot(i);
      }
      final held = [for (var i = 0; i < 256; i++) await dot(i)];
      for (var i = 0; i < 256; i++) {
        expect(identical(await dot(i), held[i]), isTrue, reason: '$i');
      }
      await dot(2000);
      expect(identical(await dot(0), held[0]), isFalse);
    });
  });
}
