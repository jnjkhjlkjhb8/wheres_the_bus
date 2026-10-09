import 'dart:async';

import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:firebase_performance/firebase_performance.dart';
import 'package:firebase_remote_config/firebase_remote_config.dart';
import 'package:flutter/foundation.dart';
import 'package:wheres_the_bus/core/firebase/firebase_gate.dart';
import 'package:wheres_the_bus/core/firebase/firebase_notifications.dart';
import 'package:wheres_the_bus/core/firebase/firebase_telemetry.dart';
import 'package:wheres_the_bus/core/firebase/remote_config.dart';
import 'package:wheres_the_bus/core/firebase/subscription_sync.dart';
import 'package:wheres_the_bus/core/storage/hive_store.dart';
import 'package:wheres_the_bus/data/repositories/firebase_repository.dart';
import 'package:wheres_the_bus/firebase_options.dart';

class FirebaseTokenSyncGuard {
  String? _lastKey;
  String? _inFlightKey;
  Future<void>? _inFlight;

  Future<void> run(
    String token,
    String prefsKey,
    Future<void> Function() sync,
  ) async {
    final key = '$token\u0000$prefsKey';
    if (key == _lastKey) return;
    if (key == _inFlightKey) return _inFlight;
    if (_inFlight != null) {
      try {
        await _inFlight;
      } on Object catch (_) {}
      return run(token, prefsKey, sync);
    }

    _inFlightKey = key;
    final future = Future<void>.sync(sync);
    _inFlight = future;
    try {
      await future;
      _lastKey = key;
    } finally {
      if (identical(_inFlight, future)) {
        _inFlight = null;
        _inFlightKey = null;
      }
    }
  }
}

class FirebaseBootstrap {
  FirebaseBootstrap._();

  static final _tokenSyncGuard = FirebaseTokenSyncGuard();
  static bool _notificationsInitialized = false;
  static StreamSubscription<RemoteConfigUpdate>? _remoteConfigSub;
  static StreamSubscription<String>? _tokenRefreshSub;
  static Future<void>? _coreInitFuture;

  static Future<void> initFailSoft({
    Future<void> Function({Future<void>? hiveReady}) initializer = init,
    Duration timeout = const Duration(seconds: 10),
    Future<void>? hiveReady,
  }) async {
    try {
      await initializer(hiveReady: hiveReady).timeout(timeout);
    } on Object catch (error, stack) {
      debugPrint('Firebase startup skipped: $error');
      debugPrintStack(stackTrace: stack);
      rethrow;
    }
  }

  static Future<void> runOptionalSteps(
    Iterable<Future<void> Function()> steps,
  ) async {
    for (final step in steps) {
      try {
        await step();
      } on Object catch (error, stack) {
        debugPrint('Firebase optional setup skipped: $error');
        debugPrintStack(stackTrace: stack);
      }
    }
  }

  @visibleForTesting
  static Future<void> singleFlightCoreInit(
    Future<void> Function() initializer,
  ) {
    final existing = _coreInitFuture;
    if (existing != null) return existing;
    final future = initializer();
    _coreInitFuture = future;
    unawaited(
      future.catchError((Object _, StackTrace _) {
        _coreInitFuture = null;
      }),
    );
    return future;
  }

  @visibleForTesting
  static void resetCoreInitForTesting() => _coreInitFuture = null;

  static Future<void> ensureCoreInitialized() {
    if (!FirebaseGate.enabled || Firebase.apps.isNotEmpty) {
      return Future<void>.value();
    }
    return singleFlightCoreInit(() async {
      FirebaseGate.ensureSecureTransport();
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );
    });
  }

  static Future<void> init({Future<void>? hiveReady}) async {
    if (!FirebaseGate.enabled) return;
    await ensureCoreInitialized();
    await hiveReady;
    const isProd = FirebaseGate.appEnv == 'production';
    const debugToken = FirebaseGate.appCheckDebugToken;
    final pinnedDebugToken = debugToken.isEmpty ? null : debugToken;
    await runOptionalSteps([
      () => FirebaseAppCheck.instance.activate(
        providerApple: isProd
            ? const AppleAppAttestProvider()
            : AppleDebugProvider(debugToken: pinnedDebugToken),
        providerAndroid: isProd
            ? const AndroidPlayIntegrityProvider()
            : AndroidDebugProvider(debugToken: pinnedDebugToken),
      ),
    ]);
    FlutterError.onError = (details) {
      unawaited(FirebaseCrashlytics.instance.recordFlutterFatalError(details));
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      FirebaseCrashlytics.instance
          .recordError(error, stack, fatal: true)
          .ignore();
      return true;
    };

    final remoteConfig = FirebaseRemoteConfig.instance;
    final messaging = FirebaseMessaging.instance;
    await runOptionalSteps([
      // Telemetry is not user-configurable: analytics, crash and performance
      // collection are always on, so there is no stored preference to read.
      () => FirebaseAnalytics.instance.setAnalyticsCollectionEnabled(true),
      () => FirebaseCrashlytics.instance.setCrashlyticsCollectionEnabled(true),
      () => FirebasePerformance.instance.setPerformanceCollectionEnabled(true),
      () async {
        await remoteConfig.setConfigSettings(
          RemoteConfigSettings(
            fetchTimeout: const Duration(seconds: 5),
            // Short so a cold start reflects an ops push (maintenance banner,
            // min version) quickly; foreground apps use Realtime below.
            minimumFetchInterval: const Duration(minutes: 1),
          ),
        );
        await remoteConfig.setDefaults(AppConfig.defaults);
        await remoteConfig.fetchAndActivate();
        // This init runs after runApp (fire-and-forget), so the UI already
        // built with defaults — bump to re-read the just-fetched values.
        AppConfig.version.value++;
        await _remoteConfigSub?.cancel();
        _remoteConfigSub = remoteConfig.onConfigUpdated.listen((_) async {
          await remoteConfig.activate();
          AppConfig.version.value++;
        });
      },
      () async => updatePushPreference(requested: HiveStore.pushEnabled),
      () async {
        await _tokenRefreshSub?.cancel();
        _tokenRefreshSub = messaging.onTokenRefresh.listen(_syncToken);
      },
    ]);
  }

  @visibleForTesting
  static Future<void> disposeForTesting() async {
    await _remoteConfigSub?.cancel();
    _remoteConfigSub = null;
    await _tokenRefreshSub?.cancel();
    _tokenRefreshSub = null;
  }

  static Future<bool> updatePushPreference({required bool requested}) async {
    HiveStore.pushEnabled = requested;
    debugPrint(
      '[firebase-reg] enabled=${FirebaseGate.enabled} '
      'requested=$requested',
    );
    if (!FirebaseGate.enabled) return requested;

    var enabled = false;
    // Remote kill switch: ops can disable push app-wide without a release.
    if (requested && AppConfig.getBool('push_enabled')) {
      try {
        final permission = await FirebaseMessaging.instance.requestPermission();
        enabled =
            permission.authorizationStatus == AuthorizationStatus.authorized ||
            permission.authorizationStatus == AuthorizationStatus.provisional;
      } on Object catch (_) {}
    }
    HiveStore.pushEnabled = enabled;
    if (enabled && !_notificationsInitialized) {
      try {
        await FirebaseNotifications.init();
        _notificationsInitialized = true;
      } on Object catch (_) {}
    }
    try {
      await FirebaseTelemetry.instance.notificationPermissionChanged(
        enabled: enabled,
      );
    } on Object catch (_) {}
    try {
      final token = await FirebaseMessaging.instance.getToken();
      debugPrint(
        '[firebase-reg] fcm token '
        '${token == null ? 'null' : 'len=${token.length}'}',
      );
      if (token != null && token.isNotEmpty) await _syncToken(token);
    } on Object catch (error) {
      debugPrint('[firebase-reg] getToken failed: $error');
    }
    return enabled;
  }

  static Future<void> _syncToken(String token) async {
    try {
      await _tokenSyncGuard.run(
        token,
        '${HiveStore.pushEnabled}',
        () async {
          await FirebaseRepository.instance.upsertDevice(fcmToken: token);
          debugPrint('[firebase-reg] upsertDevice ok');
          // Only now: subscription rows reference the device row, so the
          // first scope push has to follow the registration that creates it.
          SubscriptionSync.instance.start();
        },
      );
    } on Object catch (error, stack) {
      debugPrint('[firebase-reg] upsertDevice failed: $error');
      await FirebaseCrashlytics.instance.recordError(error, stack);
    }
  }
}
