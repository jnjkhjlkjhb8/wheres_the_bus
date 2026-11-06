import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter_android/google_maps_flutter_android.dart';
import 'package:google_maps_flutter_platform_interface/google_maps_flutter_platform_interface.dart';
import 'package:wheres_the_bus/app/app.dart';
import 'package:wheres_the_bus/core/assets/remote_assets.dart';
import 'package:wheres_the_bus/core/bootstrap/app_bootstrap.dart';
import 'package:wheres_the_bus/core/firebase/crash_reporter.dart';
import 'package:wheres_the_bus/core/firebase/firebase_bootstrap.dart';
import 'package:wheres_the_bus/core/firebase/firebase_gate.dart';
import 'package:wheres_the_bus/core/firebase/firebase_notifications.dart';
import 'package:wheres_the_bus/core/grpc/grpc_client.dart';
import 'package:wheres_the_bus/core/location/location_service.dart';
import 'package:wheres_the_bus/core/powersync/powersync_service.dart';
import 'package:wheres_the_bus/core/storage/hive_store.dart';
import 'package:wheres_the_bus/data/repositories/favorites_repository.dart';
import 'package:wheres_the_bus/data/repositories/offline_prefetch.dart';

Future<void> main() => startApp();

/// The seams exist because [FirebaseGate.enabled] is a compile-time constant,
/// so a test run can only reach the Firebase-enabled branches through them.
@visibleForTesting
Future<void> startApp({
  bool firebaseEnabled = FirebaseGate.enabled,
  Future<void> Function() ensureFirebaseCore =
      FirebaseBootstrap.ensureCoreInitialized,
}) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (firebaseEnabled) {
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
  }

  // Overlaps the ~370 ms cached-fix lookup with the bootstrap splash instead
  // of paying for it after, where it gates the first nearby-station query.
  LocationService.instance.prefetchLastKnown();

  // Start the maps renderer warmup first — it runs on the platform side and
  // overlaps with the Dart-side init below.
  _prewarmMapRenderer();

  final hiveReady = HiveStore.init();
  final bootstrap = AppBootstrapController(
    initHive: () => hiveReady,
    initGrpc: GrpcClient.init,
    initFirebase: () => FirebaseBootstrap.initFailSoft(hiveReady: hiveReady),
    initPowerSync: PowerSyncService.instance.init,
  );
  unawaited(ensureFirebaseCore().catchError(CrashReporter.record));
  unawaited(bootstrap.start().then((_) => _warmOfflineCache(bootstrap)));
  unawaited(RemoteAssets.instance.refresh());

  runApp(App(bootstrap: bootstrap));

  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(
      FavoritesRepository.instance.migrateLegacy().catchError(
        CrashReporter.record,
      ),
    );
  });
}

/// Delay before warming the offline cache, so its reads never compete with
/// the launch path's first nearby-stations query.
const _offlineWarmDelay = Duration(seconds: 5);

Future<void> _warmOfflineCache(AppBootstrapController bootstrap) async {
  if (bootstrap.state == AppBootstrapState.failed) return;
  await HiveStore.staticCacheSettled();
  await Future<void>.delayed(_offlineWarmDelay);
  await prefetchOfflineStatics().catchError(CrashReporter.record);
}

void _prewarmMapRenderer() {
  if (defaultTargetPlatform != TargetPlatform.android) return;
  final maps = GoogleMapsFlutterPlatform.instance;
  if (maps is GoogleMapsFlutterAndroid) {
    unawaited(maps.warmup());
  }
}
