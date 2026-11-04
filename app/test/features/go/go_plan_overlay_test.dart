import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:wheres_the_bus/data/models/plan_models.dart';
import 'package:wheres_the_bus/features/go/map/go_plan_overlay.dart';

const _from = PlanPoint(lat: 25, lng: 121);
const _middle = PlanPoint(lat: 25.1, lng: 121.1);
const _to = PlanPoint(lat: 25.2, lng: 121.2);
const _zero = PlanPoint(lat: 0, lng: 0);

PlanSection section({
  bool walk = false,
  List<PlanPoint> walkPath = const [],
  List<PlanPoint> transitPath = const [],
  PlanPoint from = _from,
  PlanPoint to = _to,
  List<PlanPoint> stops = const [],
}) => PlanSection(
  type: walk ? 'pedestrian' : 'transit',
  travelSummary: const PlanTravelSummary(duration: 60, length: 100),
  departure: PlanPlace(name: 'A', type: '', location: from, time: ''),
  arrival: PlanPlace(name: 'B', type: '', location: to, time: ''),
  transport: PlanTransport(
    mode: walk ? '' : 'BUS',
    name: '307',
    shortName: '307',
    longName: '',
    headsign: '',
    category: '',
    routeColor: '#FF0000',
  ),
  intermediateStops: [
    for (final point in stops)
      PlanStop(name: '中途站', location: point, departureTime: ''),
  ],
  walkPath: walkPath,
  transitPath: transitPath,
);

PlanRoute route(List<PlanSection> sections) => PlanRoute(
  travelTime: 60,
  startTime: '',
  endTime: '',
  transfers: 0,
  sections: sections,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final light = ColorScheme.fromSeed(seedColor: Colors.black);
  final dark = ColorScheme.fromSeed(
    seedColor: Colors.black,
    brightness: Brightness.dark,
  );

  test('walking geometry uses resolved path with paired ink and casing', () {
    final lines = routePolylines(
      route([
        section(walk: true, walkPath: [_from, _zero, _middle, _to]),
      ]),
      light,
    );
    final byId = {for (final line in lines) line.polylineId.value: line};
    expect(byId.keys, unorderedEquals(['leg_0', 'leg_0_casing']));
    expect(byId['leg_0']!.points, const [
      LatLng(25, 121),
      LatLng(25.1, 121.1),
      LatLng(25.2, 121.2),
    ]);
    expect(byId['leg_0']!.width, 7);
    expect(byId['leg_0_casing']!.width, 11);
    expect(byId['leg_0_casing']!.color, Colors.white);
    expect(byId['leg_0']!.patterns, byId['leg_0_casing']!.patterns);
    expect(byId['leg_0']!.zIndex, greaterThan(byId['leg_0_casing']!.zIndex));
  });

  test('transit follows its own path and dims only completed legs', () {
    final lines = routePolylines(
      route([
        section(walk: true, stops: [_middle]),
        section(transitPath: [_from, _middle, _to]),
      ]),
      dark,
      activeLeg: 1,
    );
    final byId = {for (final line in lines) line.polylineId.value: line};
    expect(byId.containsKey('leg_0_casing'), isFalse);
    expect(
      byId['leg_0']!.color,
      dark.onSurface.withValues(alpha: 0.3),
    );
    expect(byId['leg_1']!.points.length, 3);
    expect(byId['leg_1']!.patterns, isEmpty);
    expect(byId['leg_1']!.width, 6);
    expect(byId['leg_1']!.color.a, 1);
  });

  test('fallback includes intermediate stops and skips invalid geometry', () {
    final lines = routePolylines(
      route([
        section(stops: [_middle, _zero]),
        section(from: _zero, to: _zero),
        section(walk: true, from: _zero),
      ]),
      light,
    );
    expect(lines.length, 1);
    expect(lines.single.points, const [
      LatLng(25, 121),
      LatLng(25.1, 121.1),
      LatLng(25.2, 121.2),
    ]);
    expect(
      routePoints(
        route([
          section(from: _zero),
          section(to: _zero),
        ]),
      ),
      const [LatLng(25.2, 121.2), LatLng(25, 121)],
    );
  });

  testWidgets(
    'selected route markers keep endpoint priority and a moving puck',
    (tester) async {
      var puckTaps = 0;
      final selected = <int>[];
      final overlay = GoPlanOverlay(
        onAlternateTap: selected.add,
        onPuckTap: () => puckTaps++,
        onBitmapReady: () {},
      );
      addTearDown(overlay.dispose);
      final plan = PlanResult(
        routes: [
          route([
            section(walk: true, to: _middle),
            section(
              from: _middle,
              stops: [_middle, const PlanPoint(lat: 25.15, lng: 121.15)],
            ),
          ]),
          route([section()]),
          route([section(from: _zero, to: _zero)]),
        ],
      );
      GoMapLayer layer(
        ColorScheme scheme, {
        int? active,
        double heading = 350,
      }) => overlay.forPlan(
        result: plan,
        selectedIndex: 0,
        colors: scheme,
        activeLeg: active,
        fix: const LatLng(25.05, 121.05),
        puckHeading: heading,
      );
      layer(light);
      await tester.runAsync(() async {
        for (var attempt = 0; attempt < 200; attempt++) {
          final markers = layer(light).markers;
          if (markers.any((m) => m.markerId.value == 'nav_puck') &&
              markers.any((m) => m.markerId.value == 'stop_1_1')) {
            return;
          }
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      });
      final ready = layer(light);
      final byId = {
        for (final marker in ready.markers) marker.markerId.value: marker,
      };
      expect(
        byId.keys,
        unorderedEquals(['origin', 'dest', 'board_1', 'stop_1_1', 'nav_puck']),
      );
      expect(byId['nav_puck']!.rotation, 350);
      expect(byId['nav_puck']!.position, const LatLng(25.05, 121.05));
      byId['nav_puck']!.onTap!();
      expect(puckTaps, 1);
      ready.polylines
          .singleWhere((line) => line.polylineId.value == 'alt_1')
          .onTap!();
      expect(selected, [1]);
      final navigation = layer(light, active: 1, heading: 45);
      expect(
        navigation.polylines.any(
          (line) => line.polylineId.value.startsWith('alt_'),
        ),
        isFalse,
      );
      expect(
        navigation.markers
            .singleWhere((marker) => marker.markerId.value == 'nav_puck')
            .rotation,
        45,
      );
      layer(dark);
      await tester.runAsync(() async {
        for (var attempt = 0; attempt < 200; attempt++) {
          if (layer(dark).markers.any((m) => m.markerId.value == 'nav_puck')) {
            return;
          }
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      });
      expect(
        layer(dark).markers.any((m) => m.markerId.value == 'nav_puck'),
        isTrue,
      );
    },
  );

  testWidgets('pending endpoints populate asynchronously and invalidate', (
    tester,
  ) async {
    var updates = 0;
    final overlay = GoPlanOverlay(
      onAlternateTap: (_) {},
      onPuckTap: () {},
      onBitmapReady: () => updates++,
    );
    expect(
      overlay
          .pending(
            origin: null,
            destination: const LatLng(25, 121),
            colors: light,
          )
          .polylines,
      isEmpty,
    );
    final pending = overlay.pending(
      origin: const LatLng(25, 121),
      destination: const LatLng(26, 122),
      colors: light,
    );
    expect(pending.polylines.single.points, const [
      LatLng(25, 121),
      LatLng(26, 122),
    ]);
    await tester.runAsync(() async {
      for (var attempt = 0; attempt < 200; attempt++) {
        final markers = overlay
            .pending(
              origin: const LatLng(25, 121),
              destination: const LatLng(26, 122),
              colors: light,
            )
            .markers;
        if (markers.any((m) => m.markerId.value == 'pending_origin') &&
            markers.any((m) => m.markerId.value == 'pending_dest')) {
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    });
    final ready = overlay.pending(
      origin: const LatLng(25, 121),
      destination: const LatLng(26, 122),
      colors: light,
    );
    expect(
      ready.markers.map((m) => m.markerId.value),
      unorderedEquals(['pending_origin', 'pending_dest']),
    );
    expect(updates, 2);
    overlay
      ..invalidate()
      ..dispose()
      ..pending(
        origin: const LatLng(25, 121),
        destination: const LatLng(26, 122),
        colors: dark,
      );
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    expect(updates, 2);
  });
}
