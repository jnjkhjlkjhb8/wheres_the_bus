import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:wheres_the_bus/data/models/plan_models.dart';
import 'package:wheres_the_bus/features/go/map/go_plan_overlay.dart';
import 'package:wheres_the_bus/shared/map/marker_factory.dart';

import 'go_plan_overlay_test.dart' show route, section;

const _from = PlanPoint(lat: 25, lng: 121);
const _middle = PlanPoint(lat: 25.1, lng: 121.1);
const _to = PlanPoint(lat: 25.2, lng: 121.2);
const _stop = PlanPoint(lat: 25.05, lng: 121.05);

List<int> _bytes(BitmapDescriptor icon) =>
    (icon as BytesMapBitmap).byteData.buffer.asUint8List().toList();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final light = ColorScheme.fromSeed(seedColor: Colors.black);
  final dark = ColorScheme.fromSeed(
    seedColor: Colors.black,
    brightness: Brightness.dark,
  );

  GoPlanOverlay overlay() => GoPlanOverlay(
    onAlternateTap: (_) {},
    onPuckTap: () {},
    onBitmapReady: () {},
  );

  final plan = PlanResult(
    routes: [
      route([
        section(from: _from, to: _middle, stops: [_stop]),
        section(walk: true, from: _middle, to: _to),
      ]),
      route([section()]),
    ],
  );

  Future<GoMapLayer> settled(
    WidgetTester tester,
    GoPlanOverlay o, {
    ColorScheme? scheme,
    int? active,
  }) async {
    GoMapLayer layer() => o.forPlan(
      result: plan,
      selectedIndex: 0,
      colors: scheme ?? light,
      activeLeg: active,
      fix: const LatLng(25.07, 121.07),
    );
    layer();
    await tester.runAsync(() async {
      for (var attempt = 0; attempt < 200; attempt++) {
        if (layer().markers.length == 5) return;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    });
    return layer();
  }

  testWidgets('markers keep their stacking order and centred anchors', (
    tester,
  ) async {
    final o = overlay();
    addTearDown(o.dispose);
    final layer = await settled(tester, o);
    final byId = {for (final m in layer.markers) m.markerId.value: m};
    expect(
      byId.keys,
      unorderedEquals(['origin', 'dest', 'alight_0', 'stop_0_0', 'nav_puck']),
    );
    expect(
      {for (final e in byId.entries) e.key: e.value.zIndexInt},
      {
        'origin': 30,
        'dest': 30,
        'alight_0': 20,
        'stop_0_0': 10,
        'nav_puck': 40,
      },
    );
    for (final marker in byId.values) {
      expect(
        marker.anchor,
        const Offset(0.5, 0.5),
        reason: marker.markerId.value,
      );
    }
  });

  testWidgets('layers are memoised on result, route, leg and scheme', (
    tester,
  ) async {
    final o = overlay();
    addTearDown(o.dispose);
    final first = await settled(tester, o);
    GoMapLayer again({
      PlanResult? result,
      int selected = 0,
      int? active,
      ColorScheme? scheme,
    }) => o.forPlan(
      result: result ?? plan,
      selectedIndex: selected,
      colors: scheme ?? light,
      activeLeg: active,
    );
    expect(identical(again().polylines, first.polylines), isTrue);
    expect(identical(again(selected: 1).polylines, first.polylines), isFalse);
    expect(identical(again().polylines, first.polylines), isFalse);
    final base = again();
    expect(identical(again().polylines, base.polylines), isTrue);
    expect(identical(again(active: 1).polylines, base.polylines), isFalse);
    final withLeg = again(active: 1);
    expect(identical(again(active: 1).polylines, withLeg.polylines), isTrue);
    expect(
      identical(again(active: 1, scheme: dark).polylines, withLeg.polylines),
      isFalse,
    );
    final copy = PlanResult(routes: plan.routes);
    expect(
      identical(
        again(result: copy, active: 1, scheme: dark).polylines,
        withLeg.polylines,
      ),
      isFalse,
    );
  });

  testWidgets(
    'completed legs dim their marker bitmaps; the puck follows light',
    (tester) async {
      final o = overlay();
      addTearDown(o.dispose);
      final dimmed = await settled(tester, o, active: 1);
      final bright = await settled(tester, o);
      Marker pick(GoMapLayer l, String id) =>
          l.markers.singleWhere((m) => m.markerId.value == id);
      final expected = <String, List<int>>{};
      await tester.runAsync(() async {
        expected['origin'] = _bytes(
          await MapMarkers.dot(
            Colors.white.withValues(alpha: 0.3),
            ring: light.onSurface.withValues(alpha: 0.3),
            size: 20,
          ),
        );
        expected['puck'] = _bytes(
          await MapMarkers.navArrow(light.onSurface, Colors.white),
        );
      });
      expect(_bytes(pick(dimmed, 'origin').icon), expected['origin']);
      expect(_bytes(pick(bright, 'origin').icon), isNot(expected['origin']));
      expect(
        _bytes(pick(dimmed, 'dest').icon),
        _bytes(pick(bright, 'dest').icon),
      );
      expect(_bytes(pick(bright, 'nav_puck').icon), expected['puck']);
    },
  );

  testWidgets('a destination past the last leg is dimmed too', (tester) async {
    final o = overlay();
    addTearDown(o.dispose);
    final done = await settled(tester, o, active: 2);
    final bright = await settled(tester, o);
    List<int> dest(GoMapLayer l) =>
        _bytes(l.markers.singleWhere((m) => m.markerId.value == 'dest').icon);
    expect(dest(done), isNot(dest(bright)));
  });

  testWidgets('the dark puck rings in the elevated surface', (tester) async {
    final o = overlay();
    addTearDown(o.dispose);
    final layer = await settled(tester, o, scheme: dark);
    late List<int> expected;
    await tester.runAsync(() async {
      expected = _bytes(
        await MapMarkers.navArrow(dark.onSurface, dark.surfaceContainerHigh),
      );
    });
    expect(
      _bytes(
        layer.markers.singleWhere((m) => m.markerId.value == 'nav_puck').icon,
      ),
      expected,
    );
  });

  testWidgets('the pending line is a faint dotted guide between the ends', (
    tester,
  ) async {
    final o = overlay();
    addTearDown(o.dispose);
    GoMapLayer layer() => o.pending(
      origin: const LatLng(25, 121),
      destination: const LatLng(26, 122),
      colors: light,
    );
    layer();
    await tester.runAsync(() async {
      for (var attempt = 0; attempt < 200; attempt++) {
        if (layer().markers.length == 2) return;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    });
    final ready = layer();
    for (final marker in ready.markers) {
      expect(marker.anchor, const Offset(0.5, 0.5));
    }
    final line = ready.polylines.single;
    expect(line.width, 3);
    expect(line.color, light.onSurface.withValues(alpha: 0.45));
    expect(
      [for (final p in line.patterns) p.toJson()],
      [PatternItem.dot.toJson(), PatternItem.gap(14).toJson()],
    );
  });
}
