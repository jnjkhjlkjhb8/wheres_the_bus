import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:wheres_the_bus/core/update/update_gate.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';

void main() {
  group('UpdateGate', () {
    setUp(() {
      PackageInfo.setMockInitialValues(
        appName: 'wheres_the_bus',
        packageName: 'tw.gov.bus',
        version: '1.0.0',
        buildNumber: '1',
        buildSignature: '',
      );
      availableUpdate.value = null;
    });

    tearDown(() => availableUpdate.value = null);

    /// Pumps a gate over a marker child. Defaults keep the running 1.0.0
    /// build both supported and current, so each test moves exactly one bar.
    Future<void> pumpGate(
      WidgetTester tester, {
      required Stream<void> revisions,
      required String Function() minVersionOf,
      String Function() latestVersionOf = _atCurrent,
      String? Function() dismissedVersionOf = _nothingDismissed,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          // The force-update screen reads its copy from the i18n delegate, so
          // it only builds with one installed. Pinned to zh-TW because
          // `flutter_test` reports an en_US platform locale.
          locale: const Locale('zh'),
          localizationsDelegates: AppI18n.localizationsDelegates,
          supportedLocales: AppI18n.supportedLocales,
          home: UpdateGate(
            revisions: revisions,
            minVersionOf: minVersionOf,
            latestVersionOf: latestVersionOf,
            dismissedVersionOf: dismissedVersionOf,
            child: const Text('home'),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('re-checks on each Remote Config revision', (tester) async {
      var minVersion = '0.9.0';
      final controller = StreamController<void>.broadcast();
      addTearDown(controller.close);

      await pumpGate(
        tester,
        revisions: controller.stream,
        minVersionOf: () => minVersion,
      );

      // Current version (1.0.0) is not below the initial min (0.9.0).
      expect(find.text('home'), findsOneWidget);
      expect(find.text('請更新至最新版本'), findsNothing);

      // Remote Config raises the bar past the running version without a
      // relaunch; the gate must react to the next revision, not just the
      // initial check.
      minVersion = '5.0.0';
      controller.add(null);
      await tester.pumpAndSettle();

      expect(find.text('請更新至最新版本'), findsOneWidget);
    });

    testWidgets('publishes a nudge for a newer published build', (
      tester,
    ) async {
      final controller = StreamController<void>.broadcast();
      addTearDown(controller.close);

      await pumpGate(
        tester,
        revisions: controller.stream,
        minVersionOf: () => '0.9.0',
        latestVersionOf: () => '1.4.0',
      );

      // Nudged, never blocked: the app stays usable.
      expect(find.text('home'), findsOneWidget);
      expect(availableUpdate.value, '1.4.0');
    });

    testWidgets('a dismissal silences only that exact version', (
      tester,
    ) async {
      var latest = '1.4.0';
      final controller = StreamController<void>.broadcast();
      addTearDown(controller.close);

      await pumpGate(
        tester,
        revisions: controller.stream,
        minVersionOf: () => '0.9.0',
        latestVersionOf: () => latest,
        dismissedVersionOf: () => '1.4.0',
      );

      expect(availableUpdate.value, isNull);

      // A later release re-arms the nudge without the rider doing anything.
      latest = '1.5.0';
      controller.add(null);
      await tester.pumpAndSettle();

      expect(availableUpdate.value, '1.5.0');
    });

    testWidgets('blocking clears any pending nudge', (tester) async {
      var minVersion = '0.9.0';
      final controller = StreamController<void>.broadcast();
      addTearDown(controller.close);

      await pumpGate(
        tester,
        revisions: controller.stream,
        minVersionOf: () => minVersion,
        latestVersionOf: () => '1.4.0',
      );
      expect(availableUpdate.value, '1.4.0');

      // Once the floor rises past the running build the nudge is wrong: the
      // rail must not offer a dismissible strip behind the blocking screen.
      minVersion = '1.2.0';
      controller.add(null);
      await tester.pumpAndSettle();

      expect(find.text('請更新至最新版本'), findsOneWidget);
      expect(availableUpdate.value, isNull);
    });

    testWidgets('a retracted release clears a stale nudge', (tester) async {
      var latest = '1.4.0';
      final controller = StreamController<void>.broadcast();
      addTearDown(controller.close);

      await pumpGate(
        tester,
        revisions: controller.stream,
        minVersionOf: () => '0.9.0',
        latestVersionOf: () => latest,
      );
      expect(availableUpdate.value, '1.4.0');

      // Ops corrects an over-eager `latest_version` back to the running
      // build; the nudge has to retract, not linger.
      latest = '1.0.0';
      controller.add(null);
      await tester.pumpAndSettle();

      expect(availableUpdate.value, isNull);
    });
  });
}

String _atCurrent() => '1.0.0';

String? _nothingDismissed() => null;
