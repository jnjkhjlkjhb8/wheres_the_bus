import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/data/models/bus_models.dart';
import 'package:wheres_the_bus/features/bus/bloc/bus_route_state.dart';
import 'package:wheres_the_bus/features/bus/map/bus_route_overlay.dart';
import 'package:wheres_the_bus/l10n/app_i18n_zh.dart';

/// The bus route map layer. All of this used to live inside a 203-line
/// method on the screen's `State`, reachable only by mounting a
/// `GoogleMap` — which is why none of it had a test.
void main() {
  final i18n = AppI18nZh();

  BusStopModel stop(
    int seq,
    String uid, {
    double lat = 25.0,
    double lon = 121.5,
  }) => BusStopModel(
    stopUid: uid,
    stopName: '站$seq',
    sequence: seq,
    lat: lat,
    lon: lon,
  );

  BusVehiclePosition vehicle({
    String plate = 'ABC-123',
    double lat = 25.0,
    double lon = 121.5,
    int azimuth = 0,
    int gpsTimeUnix = 0,
    int busStatus = 0,
  }) => BusVehiclePosition(
    plate: plate,
    lat: lat,
    lon: lon,
    azimuth: azimuth,
    gpsTimeUnix: gpsTimeUnix,
    busStatus: busStatus,
  );

  BusRouteState stateWith({
    required List<BusStopModel> stops,
    List<BusVehiclePosition> vehicles = const [],
    int estimateSeconds = 300,
  }) => BusRouteState(
    route: BusRouteViewModel(
      subRouteUid: 'TPE1',
      routeName: '307',
      subRouteName: '307',
      departureStopName: 'A',
      destinationStopName: 'B',
      city: 'Taipei',
      headsignGo: 'B',
      headsignReturn: 'A',
      stopsGo: stops,
    ),
    etaMap: {
      for (final st in stops)
        'seq:0:${st.sequence}': BusStopEtaViewModel(
          stopUid: st.stopUid,
          direction: 0,
          sequence: st.sequence,
          estimateSeconds: estimateSeconds,
          nextBusTime: '',
          stopStatus: 0,
          vehiclePlates: const [],
          vehicles: st.sequence == 1 ? vehicles : const [],
        ),
    },
  );

  group('frameSignature', () {
    test('changes when a stop ETA moves', () {
      final stops = [stop(1, 'S1'), stop(2, 'S2')];
      String sigFor(int seconds) {
        final s = stateWith(stops: stops, estimateSeconds: seconds);
        return frameSignature(
          state: s,
          stops: stops,
          vehicles: const [],
          i18n: i18n,
          showsBubble: (_) => false,
        );
      }

      expect(sigFor(300), isNot(sigFor(60)));
      expect(sigFor(300), sigFor(300));
    });

    test('ignores the GPS clock of a bus showing no bubble', () {
      // gpsTimeUnix advances every live frame and only the bubble reads it. If
      // it were always in the signature, a route with no bubble on it would
      // invalidate every marker twice a minute to refresh a label nobody sees.
      final stops = [stop(1, 'S1')];
      String sigAt(int clock) {
        final v = vehicle(gpsTimeUnix: clock);
        return frameSignature(
          state: stateWith(stops: stops, vehicles: [v]),
          stops: stops,
          vehicles: [v],
          i18n: i18n,
          showsBubble: (_) => false,
        );
      }

      expect(sigAt(1000), sigAt(2000));
    });

    test('tracks the GPS clock of a bus that does show one', () {
      // The mirror: a shown bubble's freshness line has to keep ticking, so its
      // clock must be part of what invalidates the frame.
      final stops = [stop(1, 'S1')];
      String sigAt(int clock) {
        final v = vehicle(gpsTimeUnix: clock);
        return frameSignature(
          state: stateWith(stops: stops, vehicles: [v]),
          stops: stops,
          vehicles: [v],
          i18n: i18n,
          showsBubble: (_) => true,
        );
      }

      expect(sigAt(1000), isNot(sigAt(2000)));
    });
  });

  group('headingFor', () {
    const here = LatLng(25, 121.5);
    const there = LatLng(25.1, 121.5);

    test('a reported azimuth wins', () {
      expect(
        headingFor(
          azimuth: 90,
          previousTo: here,
          target: there,
          previousHeading: 10,
        ),
        90,
      );
    });

    test('azimuth 0 falls back to the bearing of the move', () {
      // TDX sends 0 for "no heading" as readily as for "due north", so the
      // reported value only counts when it is non-zero.
      final got = headingFor(
        azimuth: 0,
        previousTo: here,
        target: there,
        previousHeading: null,
      );
      expect(got, isNotNull);
      expect(got, closeTo(0, 1)); // due north
    });

    test('a bus that has not moved keeps its previous heading', () {
      expect(
        headingFor(
          azimuth: 0,
          previousTo: here,
          target: here,
          previousHeading: 42,
        ),
        42,
      );
    });

    test('with nothing to go on the mark drops its chevron', () {
      expect(
        headingFor(
          azimuth: 0,
          previousTo: null,
          target: there,
          previousHeading: null,
        ),
        isNull,
      );
    });
  });

  group('markerStyle', () {
    const cs = AppTheme.lightScheme;

    BusStopEtaViewModel eta({
      int estimateSeconds = 300,
      int stopStatus = 0,
      String nextBusTime = '',
    }) => BusStopEtaViewModel(
      stopUid: 'S1',
      direction: 0,
      sequence: 1,
      estimateSeconds: estimateSeconds,
      nextBusTime: nextBusTime,
      stopStatus: stopStatus,
      vehiclePlates: const [],
    );

    test(
      'the z-order ladder escalates with imminence, not with having a time',
      () {
        // A plain countdown and a quiet state share the floor: overlap order is
        // decided by how soon the bus is, so only 即將進站 and 進站中 climb.
        final quiet = markerStyle(
          i18n,
          eta(estimateSeconds: -1, stopStatus: 1, nextBusTime: '08:30'),
          cs,
        );
        final counting = markerStyle(i18n, eta(), cs);
        final arriving = markerStyle(i18n, eta(estimateSeconds: 0), cs);
        expect(quiet.zIndex, 0);
        expect(counting.zIndex, 0);
        expect(arriving.zIndex, greaterThan(counting.zIndex));
      },
    );

    test('a scheduled stop shows a clock glyph instead of a number', () {
      final scheduled = markerStyle(
        i18n,
        eta(estimateSeconds: -1, stopStatus: 1, nextBusTime: '08:30'),
        cs,
      );
      expect(scheduled.glyph, isNotNull);
      expect(scheduled.text, isNull);
      // The recessive form: thinner ring, shorter plate than a live countdown.
      final counting = markerStyle(i18n, eta(), cs);
      expect(scheduled.ringWidth, lessThan(counting.ringWidth));
      expect(scheduled.height, lessThan(counting.height));
    });

    test('only the arriving state changes shape', () {
      // Shape moves once, on the one state whose content is a word not a
      // number.
      expect(markerStyle(i18n, eta(estimateSeconds: 0), cs).pill, isTrue);
      expect(markerStyle(i18n, eta(), cs).pill, isFalse);
    });

    test('a stop with no reading at all still renders quietly', () {
      final unknown = markerStyle(i18n, null, cs);
      expect(unknown.zIndex, 0);
      expect(unknown.text, '–');
    });
  });

  group('paint', () {
    BusGlide glide({
      LatLng from = const LatLng(25, 121.5),
      LatLng to = const LatLng(25.1, 121.6),
      double? heading,
      bool bubble = false,
    }) => BusGlide(
      from: from,
      to: to,
      icon: BitmapDescriptor.defaultMarker,
      toHeading: heading,
      bubbleIcon: bubble ? BitmapDescriptor.defaultMarker : null,
    );

    test('interpolates the mark between the frame endpoints', () {
      final overlay = BusRouteOverlay(onStopTap: (_) {}, onVehicleTap: (_) {})
        ..debugSeedGlides({'ABC-123': glide()});

      final mid = overlay.paint(glideProgress: 0.5);
      final mark = mid.markers.firstWhere(
        (m) => m.markerId.value == 'bus:ABC-123',
      );
      expect(mark.position.latitude, closeTo(25.05, 1e-9));
      expect(mark.position.longitude, closeTo(121.55, 1e-9));
    });

    test('dims every bus except the pinned one', () {
      final overlay = BusRouteOverlay(onStopTap: (_) {}, onVehicleTap: (_) {})
        ..debugSeedGlides({'PIN-1': glide(), 'OTHER-2': glide()});

      final layer = overlay.paint(glideProgress: 1, pinnedPlate: 'PIN-1');
      double alphaOf(String plate) => layer.markers
          .firstWhere((m) => m.markerId.value == 'bus:$plate')
          .alpha;
      expect(alphaOf('PIN-1'), 1.0);
      expect(alphaOf('OTHER-2'), lessThan(1.0));
    });

    test('a bus outranks every stop plate, and its bubble outranks it', () {
      final overlay = BusRouteOverlay(onStopTap: (_) {}, onVehicleTap: (_) {})
        ..debugSeedGlides({'ABC-123': glide(bubble: true)});

      final layer = overlay.paint(glideProgress: 1);
      final bus = layer.markers.firstWhere(
        (m) => m.markerId.value == 'bus:ABC-123',
      );
      final bubble = layer.markers.firstWhere(
        (m) => m.markerId.value == 'bubble:ABC-123',
      );
      // 3 is the highest a selected stop capsule reaches.
      expect(bus.zIndexInt, greaterThan(3));
      expect(bubble.zIndexInt, greaterThan(bus.zIndexInt));
    });

    test('emits no bubble marker when the bus has none', () {
      final overlay = BusRouteOverlay(onStopTap: (_) {}, onVehicleTap: (_) {})
        ..debugSeedGlides({'ABC-123': glide()});
      final layer = overlay.paint(glideProgress: 1);
      expect(
        layer.markers.where((m) => m.markerId.value.startsWith('bubble:')),
        isEmpty,
      );
    });

    test('a mark with no usable heading is painted unrotated', () {
      final overlay = BusRouteOverlay(onStopTap: (_) {}, onVehicleTap: (_) {})
        ..debugSeedGlides({'ABC-123': glide()});
      final mark = overlay
          .paint(glideProgress: 1)
          .markers
          .firstWhere((m) => m.markerId.value == 'bus:ABC-123');
      expect(mark.rotation, 0);
      expect(mark.flat, isTrue);
    });
  });

  group('vehiclePositionsFor', () {
    test('keeps one entry per plate and drops the other direction', () {
      final v = vehicle();
      final state = BusRouteState(
        etaMap: {
          'a': BusStopEtaViewModel(
            stopUid: 'S1',
            direction: 0,
            sequence: 1,
            estimateSeconds: 60,
            nextBusTime: '',
            stopStatus: 0,
            vehiclePlates: const [],
            vehicles: [v],
          ),
          // The same bus reported again at the next stop along.
          'b': BusStopEtaViewModel(
            stopUid: 'S2',
            direction: 0,
            sequence: 2,
            estimateSeconds: 120,
            nextBusTime: '',
            stopStatus: 0,
            vehiclePlates: const [],
            vehicles: [v],
          ),
          'c': BusStopEtaViewModel(
            stopUid: 'S3',
            direction: 1,
            sequence: 1,
            estimateSeconds: 60,
            nextBusTime: '',
            stopStatus: 0,
            vehiclePlates: const [],
            vehicles: [vehicle(plate: 'RETURN-9')],
          ),
        },
      );
      final got = vehiclePositionsFor(state);
      expect(got.map((v) => v.plate), ['ABC-123']);
    });
  });

  group('resolve', () {
    testWidgets('a stop selection alone commits a frame', (tester) async {
      // Selecting a stop changes nothing the live feed sends, so if it is not
      // part of the frame signature the capsule waits for the next ETA frame —
      // up to ~30 s of nothing happening after the tap.
      final overlay = BusRouteOverlay(onStopTap: (_) {}, onVehicleTap: (_) {});
      final s = stateWith(stops: [stop(1, 'S1'), stop(2, 'S2')]);
      final colors = ColorScheme.fromSeed(seedColor: const Color(0xFF111111));
      Future<BusOverlayFrame?> resolve(String? selected) => overlay.resolve(
        state: s,
        i18n: i18n,
        colors: colors,
        glideProgress: 1,
        now: DateTime(2026),
        selectedStopUid: selected,
      );

      // Rasterising goes through Picture.toImage, which only completes off the
      // fake async zone.
      await tester.runAsync(() async {
        expect(await resolve(null), isNotNull);
        expect(await resolve('S1'), isNotNull);
        expect(await resolve('S1'), isNull);
      });
    });
  });

  group('boundsOf', () {
    test('spans every point', () {
      final b = boundsOf(const [
        LatLng(25, 121.5),
        LatLng(25.2, 121.4),
        LatLng(24.9, 121.7),
      ]);
      expect(b.southwest.latitude, 24.9);
      expect(b.northeast.latitude, 25.2);
      expect(b.southwest.longitude, 121.4);
      expect(b.northeast.longitude, 121.7);
    });
  });
}
