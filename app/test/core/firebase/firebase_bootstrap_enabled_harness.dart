import 'dart:async';
import 'dart:io';

import 'package:firebase_analytics_platform_interface/firebase_analytics_platform_interface.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:firebase_messaging_platform_interface/firebase_messaging_platform_interface.dart';
import 'package:firebase_remote_config_platform_interface/firebase_remote_config_platform_interface.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:wheres_the_bus/core/firebase/crash_reporter.dart';
import 'package:wheres_the_bus/core/firebase/firebase_bootstrap.dart';
import 'package:wheres_the_bus/core/firebase/firebase_gate.dart';
import 'package:wheres_the_bus/core/firebase/firebase_notifications.dart';
import 'package:wheres_the_bus/core/firebase/remote_config.dart';
import 'package:wheres_the_bus/core/grpc/grpc_client.dart';
import 'package:wheres_the_bus/core/lifecycle/app_foreground.dart';
import 'package:wheres_the_bus/core/storage/hive_store.dart';

class _Core extends MockFirebaseApp {
  @override
  Future<List<CoreInitializeResponse>> initializeCore() async => [];
  @override
  Future<CoreInitializeResponse> initializeApp(
    String name,
    CoreFirebaseOptions options,
  ) async => CoreInitializeResponse(
    name: name,
    options: options,
    pluginConstants: {
      'plugins.flutter.io/firebase_crashlytics': {
        'isCrashlyticsCollectionEnabled': true,
      },
    },
  );
}

class _Messaging extends FirebaseMessagingPlatform {
  final refresh = StreamController<String>.broadcast();
  AuthorizationStatus permission = AuthorizationStatus.authorized;
  int requests = 0;
  int presentations = 0;
  String? token;
  bool failPermission = false;
  bool failToken = false;
  bool failPresentation = false;

  @override
  FirebaseMessagingPlatform delegateFor({required FirebaseApp app}) => this;
  @override
  FirebaseMessagingPlatform setInitialValues({bool? isAutoInitEnabled}) => this;
  @override
  Stream<String> get onTokenRefresh => refresh.stream;
  @override
  Future<String?> getToken({
    String? vapidKey,
    String? serviceWorkerScriptPath,
  }) async {
    if (failToken) throw StateError('token unavailable');
    return token;
  }

  @override
  Future<NotificationSettings> requestPermission({
    bool alert = true,
    bool announcement = false,
    bool badge = true,
    bool carPlay = false,
    bool criticalAlert = false,
    bool provisional = false,
    bool sound = true,
    bool providesAppNotificationSettings = false,
  }) async {
    requests++;
    if (failPermission) throw StateError('permission unavailable');
    return NotificationSettings(
      authorizationStatus: permission,
      alert: AppleNotificationSetting.enabled,
      announcement: AppleNotificationSetting.disabled,
      badge: AppleNotificationSetting.enabled,
      carPlay: AppleNotificationSetting.disabled,
      criticalAlert: AppleNotificationSetting.disabled,
      lockScreen: AppleNotificationSetting.enabled,
      notificationCenter: AppleNotificationSetting.enabled,
      providesAppNotificationSettings: AppleNotificationSetting.disabled,
      showPreviews: AppleShowPreviewSetting.always,
      sound: AppleNotificationSetting.enabled,
      timeSensitive: AppleNotificationSetting.disabled,
    );
  }

  @override
  Future<void> setForegroundNotificationPresentationOptions({
    required bool alert,
    required bool badge,
    required bool sound,
  }) async {
    presentations++;
    if (failPresentation) throw StateError('presentation unavailable');
    expect([alert, badge, sound], [true, true, true]);
  }

  @override
  Future<RemoteMessage?> getInitialMessage() async => null;
}

class _RemoteConfig extends FirebaseRemoteConfigPlatform {
  final updates = StreamController<RemoteConfigUpdate>.broadcast();
  bool pushEnabled = true;
  bool failReads = false;
  String bannerText = 'planned maintenance';
  int approachingSeconds = 45;
  int fetches = 0;
  bool failFetch = false;
  int activations = 0;
  RemoteConfigSettings? configured;
  Map<String, dynamic>? defaults;

  @override
  FirebaseRemoteConfigPlatform delegateFor({required FirebaseApp app}) => this;
  @override
  FirebaseRemoteConfigPlatform setInitialValues({
    required Map<dynamic, dynamic> remoteConfigValues,
  }) => this;
  @override
  bool getBool(String key) {
    if (failReads) throw StateError('remote config unavailable');
    return key == 'push_enabled' && pushEnabled;
  }

  @override
  String getString(String key) {
    if (failReads) throw StateError('remote config unavailable');
    if (key == 'maintenance_banner_text') return bannerText;
    return super.getString(key);
  }

  @override
  int getInt(String key) {
    if (failReads) throw StateError('remote config unavailable');
    if (key == 'eta_approaching_threshold_s') return approachingSeconds;
    return super.getInt(key);
  }

  @override
  Future<void> setConfigSettings(RemoteConfigSettings settings) async {
    configured = settings;
  }

  @override
  Future<void> setDefaults(Map<String, dynamic> value) async {
    defaults = value;
  }

  @override
  Future<bool> fetchAndActivate() async {
    fetches++;
    if (failFetch) throw StateError('remote config offline');
    return true;
  }

  @override
  Future<bool> activate() async {
    activations++;
    return true;
  }

  @override
  Stream<RemoteConfigUpdate> get onConfigUpdated => updates.stream;
}

class _Analytics extends FirebaseAnalyticsPlatform {
  final events = <(String, Map<String, Object?>?)>[];
  bool? collection;
  bool fail = false;
  @override
  FirebaseAnalyticsPlatform delegateFor({
    required FirebaseApp app,
    Map<String, dynamic>? webOptions,
  }) => this;
  @override
  Future<void> setAnalyticsCollectionEnabled(bool enabled) async {
    collection = enabled;
  }

  @override
  Future<void> logEvent({
    required String name,
    Map<String, Object?>? parameters,
    AnalyticsCallOptions? callOptions,
  }) async {
    if (fail) throw StateError('analytics unavailable');
    events.add((name, parameters));
  }
}

const _appCheckActivate = BasicMessageChannel<Object?>(
  'dev.flutter.pigeon.firebase_app_check_platform_interface.'
  'FirebaseAppCheckHostApi.activate',
  StandardMessageCodec(),
);
const _performanceCollection = BasicMessageChannel<Object?>(
  'dev.flutter.pigeon.firebase_performance_platform_interface.'
  'FirebasePerformanceHostApi.setPerformanceCollectionEnabled',
  StandardMessageCodec(),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messaging = _Messaging();
  final remote = _RemoteConfig();
  final analytics = _Analytics();
  late Directory storage;
  late FirebaseMessagingPlatform originalMessaging;
  late FirebaseRemoteConfigPlatform originalRemote;
  late FirebaseAnalyticsPlatform originalAnalytics;
  late FlutterExceptionHandler? errorHandler;
  late bool Function(Object, StackTrace)? platformErrorHandler;
  final crashes = <MethodCall>[];
  final appCheckActivations = <Object?>[];
  final performanceCollection = <Object?>[];

  setUpAll(() async {
    expect(
      FirebaseGate.enabled,
      isTrue,
      reason: 'Run this suite with env/quality-firebase.json',
    );
    originalMessaging = FirebaseMessagingPlatform.instance;
    originalRemote = FirebaseRemoteConfigPlatform.instance;
    originalAnalytics = FirebaseAnalyticsPlatform.instance;
    TestFirebaseCoreHostApi.setUp(_Core());
    FirebaseMessagingPlatform.instance = messaging;
    FirebaseRemoteConfigPlatform.instance = remote;
    FirebaseAnalyticsPlatform.instance = analytics;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      ..setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/firebase_crashlytics'),
        (call) async {
          crashes.add(call);
          if (call.method == 'Crashlytics#setCrashlyticsCollectionEnabled') {
            return {'isCrashlyticsCollectionEnabled': true};
          }
          return null;
        },
      )
      ..setMockMethodCallHandler(
        const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
        (_) async => throw PlatformException(code: 'keychain-unavailable'),
      )
      ..setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/firebase_app_check'),
        (_) async => null,
      )
      ..setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/firebase_performance'),
        (_) async => null,
      );
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    expect(
      messenger.checkMockMessageHandler(_appCheckActivate.name, null),
      isTrue,
    );
    expect(
      messenger.checkMockMessageHandler(_performanceCollection.name, null),
      isTrue,
    );
    messenger
      ..setMockDecodedMessageHandler<Object?>(_appCheckActivate, (
        message,
      ) async {
        appCheckActivations.add(message);
        return <Object?>[null];
      })
      ..setMockDecodedMessageHandler<Object?>(_performanceCollection, (
        message,
      ) async {
        performanceCollection.add(message);
        return <Object?>[null];
      });
    storage = await Directory.systemTemp.createTemp('firebase-enabled-test-');
    Hive.init(storage.path);
    await Hive.openBox<dynamic>('settings');
    await FirebaseBootstrap.ensureCoreInitialized();
  });
  setUp(() {
    errorHandler = FlutterError.onError;
    platformErrorHandler = PlatformDispatcher.instance.onError;
    messaging
      ..permission = AuthorizationStatus.authorized
      ..requests = 0
      ..token = null
      ..failPermission = false
      ..failToken = false
      ..failPresentation = false;
    remote
      ..pushEnabled = true
      ..failReads = false
      ..failFetch = false;
    analytics
      ..fail = false
      ..events.clear();
    crashes.clear();
    appCheckActivations.clear();
    performanceCollection.clear();
  });
  tearDown(() async {
    FlutterError.onError = errorHandler;
    PlatformDispatcher.instance.onError = platformErrorHandler;
    await FirebaseBootstrap.disposeForTesting();
  });
  tearDownAll(() async {
    try {
      await Future.wait([messaging.refresh.close(), remote.updates.close()]);
    } finally {
      FirebaseMessagingPlatform.instance = originalMessaging;
      FirebaseRemoteConfigPlatform.instance = originalRemote;
      FirebaseAnalyticsPlatform.instance = originalAnalytics;
      TestFirebaseCoreHostApi.setUp(null);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        ..setMockDecodedMessageHandler<Object?>(_appCheckActivate, null)
        ..setMockDecodedMessageHandler<Object?>(_performanceCollection, null);
      try {
        await Hive.close();
      } finally {
        await storage.delete(recursive: true);
      }
    }
  });

  test(
    'permission errors leave push disabled and notification setup retryable',
    () async {
      messaging.failPermission = true;
      expect(
        await FirebaseBootstrap.updatePushPreference(requested: true),
        isFalse,
      );
      expect(HiveStore.pushEnabled, isFalse);
      messaging
        ..failPermission = false
        ..failPresentation = true;
      final before = messaging.presentations;
      expect(
        await FirebaseBootstrap.updatePushPreference(requested: true),
        isTrue,
      );
      messaging.failPresentation = false;
      expect(
        await FirebaseBootstrap.updatePushPreference(requested: true),
        isTrue,
      );
      expect(messaging.presentations, before + 2);
      expect(
        await FirebaseBootstrap.updatePushPreference(requested: true),
        isTrue,
      );
      expect(messaging.presentations, before + 2);
    },
  );
  for (final status in AuthorizationStatus.values) {
    test('push mirrors OS authorization $status', () async {
      messaging.permission = status;
      final enabled =
          status == AuthorizationStatus.authorized ||
          status == AuthorizationStatus.provisional;
      expect(
        await FirebaseBootstrap.updatePushPreference(requested: true),
        enabled,
      );
      expect(HiveStore.pushEnabled, enabled);
      expect(messaging.requests, 1);
      expect(analytics.events.map((event) => [event.$1, event.$2]).toList(), [
        [
          'notification_permission_changed',
          {'enabled': enabled ? 1 : 0},
        ],
      ]);
    });
  }
  test(
    'disabled request and remote kill switch never request OS permission',
    () async {
      expect(
        await FirebaseBootstrap.updatePushPreference(requested: false),
        isFalse,
      );
      remote.pushEnabled = false;
      expect(
        await FirebaseBootstrap.updatePushPreference(requested: true),
        isFalse,
      );
      expect(messaging.requests, 0);
      expect(HiveStore.pushEnabled, isFalse);
    },
  );
  test(
    'telemetry and token failures preserve the allowed preference',
    () async {
      final originalPrint = debugPrint;
      final diagnostics = <String>[];
      debugPrint = (message, {wrapWidth}) {
        if (message != null) diagnostics.add(message);
      };
      try {
        analytics.fail = true;
        messaging.failToken = true;
        expect(
          await FirebaseBootstrap.updatePushPreference(requested: true),
          isTrue,
        );
        expect(HiveStore.pushEnabled, isTrue);
        expect(diagnostics.join('\n'), contains('enabled=true requested=true'));
        expect(diagnostics.join('\n'), contains('token unavailable'));
        expect(
          crashes.where((call) => call.method == 'Crashlytics#recordError'),
          isEmpty,
        );

        diagnostics.clear();
        messaging
          ..failToken = false
          ..token = null;
        expect(
          await FirebaseBootstrap.updatePushPreference(requested: true),
          isTrue,
        );
        expect(diagnostics.join('\n'), contains('fcm token null'));
        expect(
          crashes.where((call) => call.method == 'Crashlytics#recordError'),
          isEmpty,
        );

        diagnostics.clear();
        messaging.token = '';
        expect(
          await FirebaseBootstrap.updatePushPreference(requested: true),
          isTrue,
        );
        expect(diagnostics.join('\n'), contains('fcm token len=0'));
        expect(
          crashes.where((call) => call.method == 'Crashlytics#recordError'),
          isEmpty,
        );

        diagnostics.clear();
        messaging.token = 'fcm-device';
        expect(
          await FirebaseBootstrap.updatePushPreference(requested: true),
          isTrue,
        );
        final registrationErrors = crashes
            .where((call) => call.method == 'Crashlytics#recordError')
            .toList();
        expect(registrationErrors, hasLength(1));
        final arguments =
            registrationErrors.single.arguments as Map<Object?, Object?>;
        expect(
          arguments['exception'].toString(),
          contains('keychain-unavailable'),
        );
        expect(diagnostics.join('\n'), contains('fcm token len=10'));
        expect(diagnostics.join('\n'), contains('keychain-unavailable'));
        expect(diagnostics.join('\n'), isNot(contains('fcm-device')));
        expect(HiveStore.pushEnabled, isTrue);
      } finally {
        debugPrint = originalPrint;
      }
    },
  );
  test(
    'bootstrap waits for Hive before configuring optional services',
    () async {
      final hiveReady = Completer<void>();
      final fetches = remote.fetches;
      final startup = FirebaseBootstrap.init(hiveReady: hiveReady.future)
        ..ignore();
      try {
        await Future<void>.delayed(Duration.zero);
        expect(appCheckActivations, isEmpty);
        expect(performanceCollection, isEmpty);
        expect(remote.fetches, fetches);
        hiveReady.complete();
        await startup;
        expect(appCheckActivations, hasLength(1));
        expect(performanceCollection, [
          [true],
        ]);
        expect(remote.fetches, fetches + 1);
      } finally {
        if (!hiveReady.isCompleted) hiveReady.complete();
        await startup;
      }
    },
  );

  test(
    'bootstrap configures telemetry and activates refreshed config once',
    () async {
      final oldVersion = AppConfig.version.value;
      await FirebaseBootstrap.init(hiveReady: Future<void>.value());
      expect(analytics.collection, isTrue);
      expect(FirebaseGate.appEnv, 'test');
      expect(FirebaseGate.appCheckDebugToken, isEmpty);
      expect(appCheckActivations, [
        ['[DEFAULT]', 'debug', 'debug', null, null],
      ]);
      expect(performanceCollection, [
        [true],
      ]);
      expect(
        crashes
            .where(
              (call) =>
                  call.method == 'Crashlytics#setCrashlyticsCollectionEnabled',
            )
            .map((call) => call.arguments),
        [
          {'enabled': true},
        ],
      );
      expect(remote.defaults, AppConfig.defaults);
      expect(remote.configured!.fetchTimeout, const Duration(seconds: 5));
      expect(
        remote.configured!.minimumFetchInterval,
        const Duration(minutes: 1),
      );
      expect(AppConfig.version.value, oldVersion + 1);
      remote.updates.add(RemoteConfigUpdate({'push_enabled'}));
      await Future<void>.delayed(Duration.zero);
      expect(remote.activations, 1);
      expect(AppConfig.version.value, oldVersion + 2);
      final error = StateError('renderer');
      FlutterError.onError!(FlutterErrorDetails(exception: error));
      expect(
        PlatformDispatcher.instance.onError!(error, StackTrace.current),
        isTrue,
      );
      await Future<void>.delayed(Duration.zero);
      expect(
        crashes.where((call) => call.method == 'Crashlytics#recordError'),
        hasLength(2),
      );
      for (final call in crashes.where(
        (call) => call.method == 'Crashlytics#recordError',
      )) {
        final arguments = call.arguments as Map<Object?, Object?>;
        expect(arguments['fatal'], isTrue);
        expect(arguments['exception'].toString(), contains(error.toString()));
      }
    },
  );
  test('notification delivery reports kind and foreground context', () async {
    FirebaseMessagingPlatform.onMessage.add(
      const RemoteMessage(data: {'kind': 'train_delay'}),
    );
    FirebaseMessagingPlatform.onMessageOpenedApp.add(
      const RemoteMessage(data: {'kind': 'metro_alert'}),
    );
    await Future<void>.delayed(Duration.zero);
    await firebaseMessagingBackgroundHandler(
      const RemoteMessage(data: {'kind': 'bus_delay'}),
    );
    expect(
      analytics.events.map((event) => [event.$1, event.$2]).toList(),
      containsAll([
        [
          'notification_received',
          {'kind': 'train_delay', 'foreground': 1},
        ],
        [
          'notification_opened',
          {'kind': 'metro_alert'},
        ],
        [
          'notification_received',
          {'kind': 'bus_delay', 'foreground': 0},
        ],
      ]),
    );
  });
  test(
    'registration commits before subscriptions and repeats coalesce',
    () async {
      final originalPrint = debugPrint;
      final diagnostics = <String>[];
      final calls = <String>[];
      final started = Completer<void>();
      final release = Completer<void>();
      messaging.token = 'registration-success-proof';
      debugPrint = (message, {wrapWidth}) {
        if (message != null) diagnostics.add(message);
      };
      var completed = false;
      final operation = FirebaseBootstrap.updatePushPreference(
        requested: true,
        registerDevice: (token) async {
          calls.add('register:$token');
          started.complete();
          await release.future;
        },
        startSubscriptions: () => calls.add('subscriptions'),
      )..ignore();
      final observed = operation.then((result) {
        completed = true;
        return result;
      })..ignore();
      try {
        await started.future.timeout(const Duration(seconds: 5));
        expect(calls, ['register:registration-success-proof']);
        expect(completed, isFalse);
        expect(HiveStore.pushEnabled, isTrue);
        expect(diagnostics.join('\n'), isNot(contains('upsertDevice ok')));
        release.complete();
        expect(await observed, isTrue);
        expect(calls, ['register:registration-success-proof', 'subscriptions']);
        expect(
          diagnostics.where((line) => line.contains('upsertDevice ok')),
          hasLength(1),
        );
        expect(diagnostics.join('\n'), isNot(contains(messaging.token)));
        expect(
          crashes.where((call) => call.method == 'Crashlytics#recordError'),
          isEmpty,
        );
        expect(
          await FirebaseBootstrap.updatePushPreference(
            requested: true,
            registerDevice: (token) async => calls.add('repeat:$token'),
            startSubscriptions: () => calls.add('repeat subscriptions'),
          ),
          isTrue,
        );
        expect(calls, ['register:registration-success-proof', 'subscriptions']);
        expect(
          diagnostics.where((line) => line.contains('upsertDevice ok')),
          hasLength(1),
        );
      } finally {
        if (!release.isCompleted) release.complete();
        try {
          await Future.wait<bool>([operation, observed]);
        } finally {
          debugPrint = originalPrint;
        }
      }
    },
  );

  test('failed registration never starts subscriptions', () async {
    final originalPrint = debugPrint;
    final diagnostics = <String>[];
    final failure = StateError('device registration rejected');
    var starts = 0;
    messaging.token = 'registration-failure-proof';
    debugPrint = (message, {wrapWidth}) {
      if (message != null) diagnostics.add(message);
    };
    try {
      expect(
        await FirebaseBootstrap.updatePushPreference(
          requested: true,
          registerDevice: (token) async {
            expect(token, 'registration-failure-proof');
            throw failure;
          },
          startSubscriptions: () => starts++,
        ),
        isTrue,
      );
      expect(starts, 0);
      expect(HiveStore.pushEnabled, isTrue);
      expect(diagnostics.join('\n'), contains(failure.toString()));
      expect(diagnostics.join('\n'), isNot(contains('upsertDevice ok')));
      final registrationErrors = crashes
          .where((call) => call.method == 'Crashlytics#recordError')
          .toList();
      expect(registrationErrors, hasLength(1));
      final arguments =
          registrationErrors.single.arguments as Map<Object?, Object?>;
      expect(arguments['exception'].toString(), contains(failure.toString()));
    } finally {
      debugPrint = originalPrint;
    }
  });

  test(
    'enabled configuration reads typed remote values and falls back on failure',
    () {
      final oldPushEnabled = remote.pushEnabled;
      final oldFailReads = remote.failReads;
      try {
        remote.pushEnabled = false;
        expect(AppConfig.getBool('push_enabled'), isFalse);
        expect(
          AppConfig.getString('maintenance_banner_text'),
          'planned maintenance',
        );
        expect(AppConfig.getInt('eta_approaching_threshold_s'), 45);

        remote.failReads = true;
        expect(AppConfig.getBool('push_enabled'), isTrue);
        expect(AppConfig.getString('maintenance_banner_text'), '');
        expect(AppConfig.getInt('eta_approaching_threshold_s'), 30);
        expect(AppConfig.getInt('nearby_fallback_radius_m'), 900);
      } finally {
        remote
          ..pushEnabled = oldPushEnabled
          ..failReads = oldFailReads;
      }
    },
  );

  test('refresh advances config only after a successful fetch', () async {
    final version = AppConfig.version.value;
    expect(await AppConfig.refresh(), isTrue);
    expect(AppConfig.version.value, version + 1);
    remote.failFetch = true;
    expect(await AppConfig.refresh(), isFalse);
    expect(AppConfig.version.value, version + 1);
    CrashReporter.record(StateError('transport failed'), StackTrace.current);
    await Future<void>.delayed(Duration.zero);
    expect(
      crashes.where((call) => call.method == 'Crashlytics#recordError'),
      hasLength(1),
    );
  });

  test('gRPC observes resume once and rebuilds its existing channel', () async {
    await GrpcClient.init();
    final generation = GrpcClient.instance.channelGeneration;
    await GrpcClient.init();
    expect(GrpcClient.instance.channelGeneration, generation);
    AppForeground.value.value = false;
    expect(GrpcClient.instance.channelGeneration, generation);
    AppForeground.value.value = true;
    expect(GrpcClient.instance.channelGeneration, generation + 1);
    await GrpcClient.instance.shutdown();
  });
}
