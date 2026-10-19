import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter_android/google_maps_flutter_android.dart';
import 'package:firebase_messaging_platform_interface/firebase_messaging_platform_interface.dart';
import 'package:google_maps_flutter_platform_interface/google_maps_flutter_platform_interface.dart';
import 'package:wheres_the_bus/app/app.dart';
import 'package:wheres_the_bus/core/bootstrap/app_bootstrap.dart';
import 'package:wheres_the_bus/core/firebase/firebase_notifications.dart';
import 'package:wheres_the_bus/core/grpc/grpc_client.dart';
import 'package:wheres_the_bus/core/lifecycle/app_foreground.dart';
import 'package:wheres_the_bus/core/lifecycle/app_network.dart';
import 'package:wheres_the_bus/main.dart' as entry;

class _AndroidMaps extends GoogleMapsFlutterAndroid {
  int warmups = 0;
  @override
  Future<void> warmup() async {
    warmups++;
  }
}

class _OtherMaps extends GoogleMapsFlutterPlatform {}

void main() {
  late GoogleMapsFlutterPlatform maps;
  var storageLookups = 0;
  setUp(() {
    storageLookups = 0;
    maps = GoogleMapsFlutterPlatform.instance;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      ..setMockMethodCallHandler(
        const MethodChannel('dev.fluttercommunity.plus/connectivity_status'),
        (_) async => null,
      )
      ..setMockMethodCallHandler(
        const MethodChannel('dev.fluttercommunity.plus/connectivity'),
        (_) async => ['none'],
      )
      ..setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/firebase_messaging'),
        (_) async => null,
      )
      ..setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (_) async {
          storageLookups++;
          throw PlatformException(code: 'storage-unavailable');
        },
      );
  });
  tearDown(() async {
    GoogleMapsFlutterPlatform.instance = maps;
    debugDefaultTargetPlatformOverride = null;
    FirebaseMessagingPlatform.onBackgroundMessage = null;
    AppForeground.reset();
    AppNetwork.reset();
    await GrpcClient.instance.shutdown();
  });

  Future<void> failedStartup(
    WidgetTester tester, {
    bool firebaseEnabled = false,
    Future<void> Function()? ensureFirebaseCore,
  }) async {
    await entry.startApp(
      firebaseEnabled: firebaseEnabled,
      ensureFirebaseCore: ensureFirebaseCore ?? () async {},
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pumpAndSettle();
    final app = tester.widget<App>(find.byType(App));
    expect(app.bootstrap.state, AppBootstrapState.failed);
    expect(app.bootstrap.lastErrorPhase, AppBootstrapFailurePhase.storage);
    expect(find.byKey(const Key('bootstrapRetryButton')), findsOneWidget);
    await tester.tap(find.byKey(const Key('bootstrapRetryButton')));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pumpAndSettle();
    expect(app.bootstrap.state, AppBootstrapState.failed);
    await tester.pumpWidget(const SizedBox.shrink());
    app.bootstrap.dispose();
    debugDefaultTargetPlatformOverride = null;
  }

  testWidgets('Android warms the map while bootstrap failure stays retryable', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final maps = _AndroidMaps();
    GoogleMapsFlutterPlatform.instance = maps;
    await failedStartup(tester);
    expect(maps.warmups, 1);
  });

  testWidgets('iOS does not warm the Android renderer', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final maps = _AndroidMaps();
    GoogleMapsFlutterPlatform.instance = maps;
    await failedStartup(tester);
    expect(maps.warmups, 0);
  });

  testWidgets('Android accepts a map platform without renderer warmup', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    GoogleMapsFlutterPlatform.instance = _OtherMaps();
    await failedStartup(tester);
  });

  testWidgets('background messages are handled only when Firebase is on', (
    tester,
  ) async {
    await failedStartup(tester);
    expect(FirebaseMessagingPlatform.onBackgroundMessage, isNull);
    await failedStartup(tester, firebaseEnabled: true);
    expect(
      FirebaseMessagingPlatform.onBackgroundMessage,
      same(firebaseMessagingBackgroundHandler),
    );
  });

  testWidgets('core Firebase init starts once and its failure is contained', (
    tester,
  ) async {
    var starts = 0;
    await failedStartup(
      tester,
      ensureFirebaseCore: () async {
        starts++;
        throw StateError('core init failed');
      },
    );
    expect(starts, 1);
  });

  testWidgets('favorites migration reopens storage after the first frame', (
    tester,
  ) async {
    await failedStartup(tester);
    // Counts every storage lookup of a failed launch: the remote-asset mirror
    // takes one, and the post-frame legacy migration is the one that keeps
    // retrying after the bootstrap gave up.
    expect(storageLookups, 4);
  });
}
