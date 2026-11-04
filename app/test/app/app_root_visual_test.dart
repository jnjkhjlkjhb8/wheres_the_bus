import 'dart:io';

import 'dart:ui' as ui;

import 'package:connectivity_plus_platform_interface/connectivity_plus_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:skeletonizer/skeletonizer.dart';
import 'package:wheres_the_bus/app/app.dart';
import 'package:wheres_the_bus/core/bootstrap/app_bootstrap.dart';
import 'package:wheres_the_bus/core/lifecycle/app_foreground.dart';
import 'package:wheres_the_bus/core/lifecycle/app_network.dart';
import 'package:wheres_the_bus/core/live_activity/alight_track_inbound_channel.dart';
import 'package:wheres_the_bus/core/storage/hive_store.dart';
import 'package:wheres_the_bus/shared/map/marker_factory.dart';

class _WifiConnectivity extends ConnectivityPlatform {
  @override
  Future<List<ConnectivityResult>> checkConnectivity() async => const [
    ConnectivityResult.wifi,
  ];

  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged =>
      const Stream<List<ConnectivityResult>>.empty();
}

void main() {
  late Directory storage;
  late ConnectivityPlatform originalConnectivity;
  late bool originalInitialized;

  setUpAll(() async {
    storage = await Directory.systemTemp.createTemp('app-root-visual-');
    Hive.init(storage.path);
    await HiveStore.init(initBinding: () async {});
    await HiveStore.settings.clear();
  });

  tearDownAll(() async {
    try {
      await Hive.close().timeout(const Duration(seconds: 5));
    } finally {
      if (storage.existsSync()) await storage.delete(recursive: true);
    }
  });

  setUp(() {
    originalConnectivity = ConnectivityPlatform.instance;
    originalInitialized = App.isInitialized.value;
    AppNetwork.reset();
    ConnectivityPlatform.instance = _WifiConnectivity();
  });

  tearDown(() {
    MapMarkers.configure(devicePixelRatio: 3);
    AlightTrackInboundChannel.reset();
    AppForeground.reset();
    AppNetwork.reset();
    ConnectivityPlatform.instance = originalConnectivity;
    App.isInitialized.value = originalInitialized;
  });

  Future<void> mountReady(WidgetTester tester) async {
    final controller = AppBootstrapController(
      initHive: () async {},
      initGrpc: () async {},
      initFirebase: () async {},
      initPowerSync: () async {},
    );
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const Scaffold(
            body: Text('root-visual-probe'),
          ),
        ),
      ],
    );
    addTearDown(() async {
      await tester.runAsync(() => tester.pumpWidget(const SizedBox.shrink()));
      router.dispose();
      controller.dispose();
    });
    await controller.start();
    await tester.pumpWidget(App(bootstrap: controller, debugRouter: router));
    await tester.pumpAndSettle();
    expect(find.text('root-visual-probe'), findsOneWidget);
  }

  for (final reduceMotion in [false, true]) {
    testWidgets('loading content respects reduce motion: $reduceMotion', (
      tester,
    ) async {
      tester.binding.platformDispatcher.accessibilityFeaturesTestValue =
          FakeAccessibilityFeatures(disableAnimations: reduceMotion);
      addTearDown(
        tester.binding.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await mountReady(tester);

      final context = tester.element(find.text('root-visual-probe'));
      final effect = SkeletonizerConfig.of(
        context,
      ).resolveEffect(Theme.of(context).brightness);
      expect(MediaQuery.disableAnimationsOf(context), reduceMotion);
      if (reduceMotion) {
        expect(effect, isA<SolidColorEffect>());
        expect(effect.duration, Duration.zero);
        expect(
          (effect as SolidColorEffect).color,
          Theme.of(context).colorScheme.surfaceContainerHighest,
        );
      } else {
        expect(effect, isA<ShimmerEffect>());
        expect(effect.duration, greaterThan(Duration.zero));
      }
    });
  }

  Future<ui.Size> markerSize(WidgetTester tester, {String? label}) async {
    // PNG encoding/decoding is native asynchronous work; the fake test clock
    // must not hold up the raster pipeline while it is being awaited.
    return (await tester.runAsync(() async {
      final marker = await MapMarkers.stopMarker(
        fill: Colors.white,
        content: Colors.black,
        text: '5',
        label: label,
      );
      final codec = await ui.instantiateImageCodec(
        (marker.icon as BytesMapBitmap).byteData,
      );
      try {
        final image = (await codec.getNextFrame()).image;
        try {
          return ui.Size(image.width.toDouble(), image.height.toDouble());
        } finally {
          image.dispose();
        }
      } finally {
        codec.dispose();
      }
    }))!;
  }

  testWidgets(
    'root display scale reaches marker PNGs and distinct stop labels',
    (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const ui.Size(1600, 1200);
      tester.binding.platformDispatcher.textScaleFactorTestValue = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(
        tester.binding.platformDispatcher.clearTextScaleFactorTestValue,
      );
      await mountReady(tester);

      final base = await markerSize(tester);
      final short = await markerSize(tester, label: 'A根');
      final long = await markerSize(tester, label: 'A根視覺測試長站名');
      expect(short.height, base.height);
      expect(long.height, base.height);
      expect(short.width, greaterThan(base.width));
      expect(long.width, greaterThan(short.width));

      // Only the platform display properties change. Calling configure here
      // would bypass the root builder whose propagation this case verifies.
      tester.view.devicePixelRatio = 2;
      await tester.pumpAndSettle();
      final dense = await markerSize(tester);
      expect(dense.width / base.width, closeTo(2, 0.03));
      expect(dense.height / base.height, closeTo(2, 0.03));

      tester.binding.platformDispatcher.textScaleFactorTestValue = 1.2;
      await tester.pumpAndSettle();
      final context = tester.element(find.text('root-visual-probe'));
      expect(MediaQuery.textScalerOf(context).scale(12), closeTo(14.4, 0.001));
      final accessible = await markerSize(tester);
      expect(accessible.width / dense.width, closeTo(1.2, 0.03));
      expect(accessible.height / dense.height, closeTo(1.2, 0.03));
    },
  );
}
