import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter_android/google_maps_flutter_android.dart';
import 'package:google_maps_flutter_platform_interface/google_maps_flutter_platform_interface.dart';
import 'package:wheres_the_bus/app/app.dart';
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

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (FirebaseGate.enabled) {
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
  unawaited(
    FirebaseBootstrap.ensureCoreInitialized().catchError(CrashReporter.record),
  );
  unawaited(bootstrap.start());

  runApp(App(bootstrap: bootstrap));

  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(
      FavoritesRepository.instance.migrateLegacy().catchError(
        CrashReporter.record,
      ),
    );
  });
}

void _prewarmMapRenderer() {
  if (defaultTargetPlatform != TargetPlatform.android) return;
  final maps = GoogleMapsFlutterPlatform.instance;
  if (maps is GoogleMapsFlutterAndroid) {
    unawaited(maps.warmup());
  }
}
