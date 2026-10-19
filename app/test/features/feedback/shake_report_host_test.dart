import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:wheres_the_bus/app/router/app_routes.dart';
import 'package:wheres_the_bus/data/repositories/settings_repository.dart';
import 'package:wheres_the_bus/features/feedback/view/shake_report_host.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';

/// Feeds a full out-back-out shake through [samples].
Future<void> _shake(
  WidgetTester tester,
  StreamController<UserAccelerometerEvent> samples,
) async {
  for (final x in [20.0, -20.0, 20.0, -20.0]) {
    samples.add(UserAccelerometerEvent(x, 0, 0, DateTime.now()));
    await tester.pump(const Duration(milliseconds: 80));
  }
  await tester.pumpAndSettle();
}

Future<void> _pump(
  WidgetTester tester,
  StreamController<UserAccelerometerEvent> samples, {
  required List<String?> openedFrom,
  String initialLocation = AppRoutes.busStop,
  bool nativeSensors = false,
}) async {
  Widget host(Widget child) => ShakeReportHost(
    samples: nativeSensors ? null : samples.stream,
    child: child,
  );
  await tester.pumpWidget(
    MaterialApp.router(
      locale: const Locale('zh'),
      localizationsDelegates: AppI18n.localizationsDelegates,
      supportedLocales: AppI18n.supportedLocales,
      routerConfig: GoRouter(
        initialLocation: initialLocation,
        routes: [
          GoRoute(
            path: AppRoutes.busStop,
            builder: (_, _) => host(const Scaffold(body: Text('stop'))),
          ),
          GoRoute(
            path: AppRoutes.feedback,
            builder: (_, state) {
              openedFrom.add(state.uri.queryParameters['from']);
              return host(const Scaffold(body: Text('form')));
            },
          ),
        ],
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  late StreamController<UserAccelerometerEvent> samples;
  late List<String?> openedFrom;

  setUpAll(() => Hive.openBox<dynamic>('settings', bytes: Uint8List(0)));
  tearDownAll(Hive.close);

  setUp(() async {
    samples = StreamController<UserAccelerometerEvent>.broadcast();
    openedFrom = [];
    await Hive.box<dynamic>(
      'settings',
    ).put(SettingsRepository.shakeToReportKey, true);
  });
  tearDown(() => samples.close());

  testWidgets('setting and lifecycle attach the sensor only while wanted', (
    tester,
  ) async {
    final binding = tester.binding;
    addTearDown(
      () => binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed),
    );
    await _pump(tester, samples, openedFrom: openedFrom);
    expect(samples.hasListener, true);
    binding
      ..handleAppLifecycleStateChanged(AppLifecycleState.inactive)
      ..handleAppLifecycleStateChanged(AppLifecycleState.hidden)
      ..handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(samples.hasListener, false);
    binding
      ..handleAppLifecycleStateChanged(AppLifecycleState.hidden)
      ..handleAppLifecycleStateChanged(AppLifecycleState.inactive)
      ..handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(samples.hasListener, true);
    await Hive.box<dynamic>(
      'settings',
    ).put(SettingsRepository.shakeToReportKey, false);
    await tester.pump();
    expect(samples.hasListener, false);
    await Hive.box<dynamic>(
      'settings',
    ).put(SettingsRepository.shakeToReportKey, false);
    await tester.pump();
    expect(samples.hasListener, false);
    await Hive.box<dynamic>(
      'settings',
    ).put(SettingsRepository.shakeToReportKey, true);
    await tester.pump();
    expect(samples.hasListener, true);
    samples.addError(StateError('sensor unavailable'));
    await tester.pump();
    expect(tester.takeException(), isNull);
    await _shake(tester, samples);
    expect(find.text('有什麼要告訴開發者的？'), findsOneWidget);
    await tester.tap(find.text('不用了'));
    await tester.pumpAndSettle();
    expect(openedFrom, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('device accelerometer samples reach the report confirmation', (
    tester,
  ) async {
    const methods = MethodChannel('dev.fluttercommunity.plus/sensors/method');
    const events = MethodChannel(
      'dev.fluttercommunity.plus/sensors/user_accel',
    );
    final calls = <MethodCall>[];
    final messenger = tester.binding.defaultBinaryMessenger
      ..setMockMethodCallHandler(methods, (call) async {
        calls.add(call);
        return null;
      })
      ..setMockMethodCallHandler(events, (call) async {
        calls.add(call);
        return null;
      });
    addTearDown(() {
      messenger
        ..setMockMethodCallHandler(methods, null)
        ..setMockMethodCallHandler(events, null);
    });
    await _pump(
      tester,
      samples,
      openedFrom: openedFrom,
      nativeSensors: true,
    );
    expect(calls.map((call) => call.method), contains('listen'));
    expect(
      calls
          .singleWhere(
            (call) => call.method == 'setUserAccelerometerSamplingPeriod',
          )
          .arguments,
      SensorInterval.gameInterval.inMicroseconds,
    );
    for (final x in [20.0, -20.0, 20.0, -20.0]) {
      tester.binding.channelBuffers.push(
        events.name,
        const StandardMethodCodec().encodeSuccessEnvelope([
          x,
          0.0,
          0.0,
          DateTime.now().microsecondsSinceEpoch.toDouble(),
        ]),
        (_) {},
      );
      await tester.pump(const Duration(milliseconds: 80));
    }
    await tester.pumpAndSettle();
    expect(find.text('有什麼要告訴開發者的？'), findsOneWidget);
    await tester.tap(find.text('不用了'));
    await tester.pumpAndSettle();
    expect(openedFrom, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(calls.map((call) => call.method), contains('cancel'));
  });

  testWidgets('a shake asks before it navigates', (tester) async {
    await _pump(tester, samples, openedFrom: openedFrom);

    await _shake(tester, samples);

    expect(find.text('有什麼要告訴開發者的？'), findsOneWidget);
    // Asking is not going: nothing has been opened yet.
    expect(openedFrom, isEmpty);
  });

  testWidgets('confirming opens the form and names the screen behind it', (
    tester,
  ) async {
    await _pump(tester, samples, openedFrom: openedFrom);
    await _shake(tester, samples);

    await tester.tap(find.text('回報問題'));
    await tester.pumpAndSettle();

    expect(find.text('form'), findsOneWidget);
    expect(openedFrom, [AppRoutes.busStop]);
  });

  testWidgets('declining leaves the rider where they were', (tester) async {
    await _pump(tester, samples, openedFrom: openedFrom);
    await _shake(tester, samples);

    await tester.tap(find.text('不用了'));
    await tester.pumpAndSettle();

    expect(find.text('有什麼要告訴開發者的？'), findsNothing);
    expect(find.text('stop'), findsOneWidget);
    expect(openedFrom, isEmpty);
  });

  // The station used to be invisible to a report: it lived in the home sheet's
  // own navigator, so the location said only `/`. Now that every station is a
  // location, the report names it with no side channel.
  testWidgets('the report names the whole location, query and all', (
    tester,
  ) async {
    final location = AppRoutes.busStopLocation(
      stopName: '台北車站',
      stopId: '1234',
    );
    await _pump(
      tester,
      samples,
      openedFrom: openedFrom,
      initialLocation: location,
    );
    await _shake(tester, samples);

    await tester.tap(find.text('回報問題'));
    await tester.pumpAndSettle();

    expect(openedFrom, [location]);
  });

  // Answering "report a problem" with the form the rider is already looking at
  // is an interface that isn't listening.
  testWidgets('shaking on the form itself does nothing', (tester) async {
    await _pump(
      tester,
      samples,
      openedFrom: openedFrom,
      initialLocation: AppRoutes.feedback,
    );

    await _shake(tester, samples);

    expect(find.text('有什麼要告訴開發者的？'), findsNothing);
    expect(find.text('form'), findsOneWidget);
  });

  testWidgets('a disposed host stays detached when the setting flips', (
    tester,
  ) async {
    await _pump(tester, samples, openedFrom: openedFrom);
    expect(samples.hasListener, true);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(samples.hasListener, false);
    final box = Hive.box<dynamic>('settings');
    await box.put(SettingsRepository.shakeToReportKey, false);
    await box.put(SettingsRepository.shakeToReportKey, true);
    await tester.pump();
    expect(samples.hasListener, false);
  });

  testWidgets('a shake while the question is open does not stack another', (
    tester,
  ) async {
    await _pump(tester, samples, openedFrom: openedFrom);
    await _shake(tester, samples);
    expect(find.text('有什麼要告訴開發者的？'), findsOneWidget);

    await tester.pump(const Duration(seconds: 2));
    await _shake(tester, samples);
    expect(find.text('有什麼要告訴開發者的？'), findsOneWidget);

    await tester.tap(find.text('不用了'));
    await tester.pumpAndSettle();
    expect(find.text('有什麼要告訴開發者的？'), findsNothing);
  });

  testWidgets('the sheet clears the home indicator by its safe-area inset', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppI18n.localizationsDelegates,
        supportedLocales: AppI18n.supportedLocales,
        home: const MediaQuery(
          data: MediaQueryData(padding: EdgeInsets.only(bottom: 34)),
          child: Scaffold(body: ShakeReportSheet()),
        ),
      ),
    );
    final padding = tester.widget<Padding>(
      find
          .descendant(
            of: find.byType(ShakeReportSheet),
            matching: find.byType(Padding),
          )
          .first,
    );
    expect(padding.padding, const EdgeInsets.fromLTRB(20, 4, 20, 54));
  });
}
