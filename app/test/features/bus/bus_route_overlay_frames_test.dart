import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/data/models/bus_models.dart';
import 'package:wheres_the_bus/features/bus/bloc/bus_route_state.dart';
import 'package:wheres_the_bus/features/bus/map/bus_route_overlay.dart';
import 'package:wheres_the_bus/l10n/app_i18n_zh.dart';

void main() {
  final i18n = AppI18nZh();
  const light = AppTheme.lightScheme;

  BusStopModel stop(
    int seq,
    String uid, {
    double lat = 25,
    double lon = 121.5,
  }) => BusStopModel(
    stopUid: uid,
    stopName: '站$seq',
    sequence: seq,
    lat: lat,
    lon: lon,
  );

  BusVehiclePosition vehicle(
    String plate, {
    int busStatus = 0,
    double lat = 25.1,
    double lon = 121.6,
  }) => BusVehiclePosition(
    plate: plate,
    lat: lat,
    lon: lon,
    azimuth: 0,
    busStatus: busStatus,
    gpsTimeUnix: 1000,
  );

  BusStopEtaViewModel eta(
    BusStopModel st, {
    int seconds = 300,
    int status = 0,
    int direction = 0,
    List<BusVehiclePosition> vehicles = const [],
  }) => BusStopEtaViewModel(
    stopUid: st.stopUid,
    direction: direction,
    sequence: st.sequence,
    estimateSeconds: seconds,
    nextBusTime: '',
    stopStatus: status,
    vehiclePlates: const [],
    vehicles: vehicles,
  );

  BusRouteState state({
    List<BusStopModel> go = const [],
    List<BusStopModel> back = const [],
    String geometryGo = '',
    String geometryBack = '',
    int direction = 0,
    Map<String, BusStopEtaViewModel> etas = const {},
  }) => BusRouteState(
    direction: direction,
    route: BusRouteViewModel(
      subRouteUid: 'R',
      routeName: '1',
      subRouteName: '1',
      departureStopName: 'A',
      destinationStopName: 'B',
      city: 'Taipei',
      headsignGo: 'B',
      headsignReturn: 'A',
      stopsGo: go,
      stopsReturn: back,
      geometryGo: geometryGo,
      geometryReturn: geometryBack,
    ),
    etaMap: etas,
  );

  BusRouteOverlay overlay() =>
      BusRouteOverlay(onStopTap: (_) {}, onVehicleTap: (_) {});

  Future<BusOverlayFrame?> resolve(
    BusRouteOverlay o,
    BusRouteState s, {
    ColorScheme? colors,
    String? selected,
    String? pinned,
    double progress = 1,
  }) => o.resolve(
    state: s,
    i18n: i18n,
    colors: colors ?? light,
    glideProgress: progress,
    now: DateTime.utc(2026),
    selectedStopUid: selected,
    pinnedPlate: pinned,
  );

  List<LatLng> pointsOf(BusOverlayFrame f) => [
    for (final p in f.polylines) ...p.points,
  ];

  group('route line', () {
    const wktGo = 'LINESTRING(121.4 25.0, 121.5 25.1)';
    const wktBack = 'LINESTRING(121.6 25.2, 121.7 25.3)';

    testWidgets('follows the geometry of the shown direction', (tester) async {
      await tester.runAsync(() async {
        final go = [stop(1, 'a'), stop(2, 'b', lat: 25.2)];
        final f0 = await resolve(
          overlay(),
          state(go: go, back: go, geometryGo: wktGo, geometryBack: wktBack),
        );
        expect(pointsOf(f0!), const [LatLng(25, 121.4), LatLng(25.1, 121.5)]);

        final f1 = await resolve(
          overlay(),
          state(
            go: go,
            back: go,
            geometryGo: wktGo,
            geometryBack: wktBack,
            direction: 1,
          ),
        );
        expect(pointsOf(f1!), const [LatLng(25.2, 121.6), LatLng(25.3, 121.7)]);
      });
    });

    testWidgets('real geometry beats the stop-to-stop fallback', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final go = [
          stop(1, 'a'),
          stop(2, 'b', lat: 25.2),
          stop(3, 'c', lat: 25.3),
        ];
        final f = await resolve(overlay(), state(go: go, geometryGo: wktGo));
        expect(f!.polylines, hasLength(1));
        expect(pointsOf(f), const [LatLng(25, 121.4), LatLng(25.1, 121.5)]);
      });
    });

    testWidgets('without geometry two or more stops are joined', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final two = [stop(1, 'a'), stop(2, 'b', lat: 25.2)];
        final f2 = await resolve(overlay(), state(go: two));
        expect(pointsOf(f2!), const [LatLng(25, 121.5), LatLng(25.2, 121.5)]);

        final three = [...two, stop(3, 'c', lat: 25.3)];
        final f3 = await resolve(overlay(), state(go: three));
        expect(pointsOf(f3!), hasLength(3));

        final one = await resolve(overlay(), state(go: [stop(1, 'a')]));
        expect(one!.polylines, isEmpty);
      });
    });

    testWidgets('the line survives a live frame of the same route', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final go = [stop(1, 'a'), stop(2, 'b', lat: 25.2)];
        final o = overlay();
        await resolve(o, state(go: go, geometryGo: wktGo));
        final f = await resolve(
          o,
          state(
            go: go,
            geometryGo: wktGo,
            etas: {'seq:0:1': eta(go.first, seconds: 60)},
          ),
        );
        expect(pointsOf(f!), const [LatLng(25, 121.4), LatLng(25.1, 121.5)]);
      });
    });
  });

  group('stop markers', () {
    testWidgets('only stops with a coordinate are drawn', (tester) async {
      await tester.runAsync(() async {
        final stops = [
          stop(1, 'both'),
          stop(2, 'lat-only', lon: 0),
          stop(3, 'lon-only', lat: 0),
          stop(4, 'neither', lat: 0, lon: 0),
        ];
        final f = await resolve(overlay(), state(go: stops));
        expect(f!.stopMarkers.map((m) => m.markerId.value).toSet(), {
          'both',
          'lat-only',
          'lon-only',
        });
        expect(f.stopPoints, hasLength(3));
      });
    });

    testWidgets('a selected stop rises above its neighbours', (tester) async {
      await tester.runAsync(() async {
        final stops = [stop(1, 'a'), stop(2, 'b', lat: 25.1)];
        final f = await resolve(overlay(), state(go: stops), selected: 'b');
        int z(String id) =>
            f!.stopMarkers.firstWhere((m) => m.markerId.value == id).zIndexInt;
        expect(z('b'), 3);
        expect(z('a'), isNot(3));
      });
    });

    testWidgets('the selected name leans away from the route middle', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final stops = [
          stop(1, 'west', lon: 121.4),
          stop(2, 'mid'),
          stop(3, 'east', lon: 121.6),
        ];
        Future<Offset> anchorOf(String uid) async {
          final f = await resolve(overlay(), state(go: stops), selected: uid);
          return f!.stopMarkers
              .firstWhere((m) => m.markerId.value == uid)
              .anchor;
        }

        final west = await anchorOf('west');
        final east = await anchorOf('east');
        expect(west, isNot(east));
        expect(west.dx + east.dx, closeTo(1, 0.2));
        expect(west.dx, greaterThan(east.dx));
      });
    });

    testWidgets('unchanged stops are reused, changed ones rebuilt', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final stops = [stop(1, 'a'), stop(2, 'b', lat: 25.1)];
        final o = overlay();
        final first = await resolve(
          o,
          state(
            go: stops,
            etas: {'seq:0:1': eta(stops[0]), 'seq:0:2': eta(stops[1])},
          ),
        );
        final second = await resolve(
          o,
          state(
            go: stops,
            etas: {
              'seq:0:1': eta(stops[0]),
              'seq:0:2': eta(stops[1], seconds: 600),
            },
          ),
        );
        Marker m(BusOverlayFrame f, String id) =>
            f.stopMarkers.firstWhere((x) => x.markerId.value == id);
        expect(second!.stopMarkers, hasLength(2));
        expect(identical(m(second, 'a'), m(first!, 'a')), isTrue);
        expect(identical(m(second, 'b'), m(first, 'b')), isFalse);
      });
    });
  });

  group('vehicles', () {
    Future<BusRouteOverlay> shown(
      WidgetTester tester,
      List<BusVehiclePosition> vehicles, {
      String? pinned,
      double progress = 1,
    }) async {
      final o = overlay();
      final stops = [stop(1, 'a')];
      await tester.runAsync(() async {
        await resolve(
          o,
          state(
            go: stops,
            etas: {'seq:0:1': eta(stops[0], vehicles: vehicles)},
          ),
          pinned: pinned,
          progress: progress,
        );
      });
      return o;
    }

    Set<String> ids(BusRouteOverlay o) =>
        o.paint(glideProgress: 1).markers.map((m) => m.markerId.value).toSet();

    testWidgets('a bubble is for the pinned bus or a warning, nothing else', (
      tester,
    ) async {
      final o = await shown(tester, [
        vehicle('PIN'),
        vehicle('OK'),
        vehicle('BAD', busStatus: 2),
      ], pinned: 'PIN');
      expect(ids(o), containsAll(['bubble:PIN', 'bubble:BAD']));
      expect(ids(o), isNot(contains('bubble:OK')));
      expect(ids(o), containsAll(['bus:PIN', 'bus:OK', 'bus:BAD']));
    });

    testWidgets('with nothing pinned a calm bus has no bubble', (tester) async {
      final o = await shown(tester, [vehicle('OK')]);
      expect(ids(o), {'a', 'bus:OK'});
    });

    testWidgets('the frame reports whether any bubble is up', (tester) async {
      final stops = [stop(1, 'a')];
      await tester.runAsync(() async {
        BusRouteState with_(List<BusVehiclePosition> v) => state(
          go: stops,
          etas: {'seq:0:1': eta(stops[0], vehicles: v)},
        );
        final calm = await resolve(overlay(), with_([vehicle('OK')]));
        expect(calm!.hasVehicles, isTrue);
        expect(calm.showsAnyBubble, isFalse);
        final warn = await resolve(
          overlay(),
          with_([vehicle('BAD', busStatus: 2)]),
        );
        expect(warn!.showsAnyBubble, isTrue);
        final none = await resolve(overlay(), with_(const []));
        expect(none!.hasVehicles, isFalse);
      });
    });

    testWidgets('a new bus sits at its reported (lat, lon)', (tester) async {
      final o = await shown(tester, [vehicle('OK', lat: 25.2, lon: 121.7)]);
      final mark = o
          .paint(glideProgress: 0)
          .markers
          .firstWhere((m) => m.markerId.value == 'bus:OK');
      expect(mark.position, const LatLng(25.2, 121.7));
      expect(mark.anchor, const Offset(0.5, 0.5));
    });

    test('a quarter of the way is not three quarters', () {
      final o = overlay()
        ..debugSeedGlides({
          'P': BusGlide(
            from: const LatLng(25, 121),
            to: const LatLng(26, 122),
            icon: BitmapDescriptor.defaultMarker,
          ),
        });
      final mark = o
          .paint(glideProgress: 0.25)
          .markers
          .firstWhere((m) => m.markerId.value == 'bus:P');
      expect(mark.position.latitude, closeTo(25.25, 1e-9));
      expect(mark.position.longitude, closeTo(121.25, 1e-9));
    });

    testWidgets('a repeat frame keeps the stop reading and glides on', (
      tester,
    ) async {
      final o = overlay();
      final stops = [stop(1, 'a')];
      BusRouteState at(double lat) => state(
        go: stops,
        etas: {
          'seq:0:1': eta(stops[0], vehicles: [vehicle('OK', lat: lat)]),
        },
      );
      await tester.runAsync(() async {
        await resolve(o, at(25.1));
        await resolve(o, at(25.3));
      });
      final glide = o.glides['OK']!;
      expect(glide.from, const LatLng(25.1, 121.6));
      expect(glide.to, const LatLng(25.3, 121.6));
    });
  });

  group('tickBubbles', () {
    BusGlide glide(
      BitmapDescriptor? bubble,
      Future<BitmapDescriptor> Function(DateTime)? rebuild,
    ) => BusGlide(
      from: const LatLng(25, 121),
      to: const LatLng(25, 121),
      icon: BitmapDescriptor.defaultMarker,
      bubbleIcon: bubble,
      rebuildBubble: rebuild,
    );

    test('swaps in a rebuilt bubble and reports the change', () async {
      final fresh = BitmapDescriptor.defaultMarkerWithHue(10);
      DateTime? asked;
      final o = overlay()
        ..debugSeedGlides({
          'A': glide(BitmapDescriptor.defaultMarker, (at) async {
            asked = at;
            return fresh;
          }),
        });

      expect(await o.tickBubbles(DateTime.utc(2026, 1, 2)), isTrue);

      expect(asked, DateTime.utc(2026, 1, 2));
      expect(o.glides['A']!.bubbleIcon, same(fresh));
    });

    test('an unchanged bubble reports no change', () async {
      const icon = BitmapDescriptor.defaultMarker;
      final o = overlay()
        ..debugSeedGlides({'A': glide(icon, (_) async => icon)});

      expect(await o.tickBubbles(DateTime.utc(2026)), isFalse);
    });

    test('a bus without a bubble is skipped', () async {
      final o = overlay()..debugSeedGlides({'A': glide(null, null)});

      expect(await o.tickBubbles(DateTime.utc(2026)), isFalse);
      expect(o.glides['A']!.bubbleIcon, isNull);
    });

    test(
      'every bus is refreshed, and one change is enough to report',
      () async {
        const a = BitmapDescriptor.defaultMarker;
        final b = BitmapDescriptor.defaultMarkerWithHue(20);
        final o = overlay()
          ..debugSeedGlides({
            'A': glide(a, (_) async => a),
            'B': glide(a, (_) async => b),
          });

        expect(await o.tickBubbles(DateTime.utc(2026)), isTrue);
        expect(o.glides['B']!.bubbleIcon, same(b));
      },
    );
  });

  testWidgets('a retargeted bus glides on from where the mark is now', (
    tester,
  ) async {
    final o = overlay();
    final stops = [stop(1, 'a')];
    BusRouteState at(double lat) => state(
      go: stops,
      etas: {
        'seq:0:1': eta(stops[0], vehicles: [vehicle('OK', lat: lat)]),
      },
    );
    await tester.runAsync(() async {
      await resolve(o, at(25.1));
      await resolve(o, at(25.3));
      await resolve(o, at(25.5), progress: 0.25);
    });

    final glide = o.glides['OK']!;
    expect(glide.from.latitude, closeTo(25.1 + 0.2 * 0.25, 1e-9));
    expect(glide.to.latitude, 25.5);
  });
}
