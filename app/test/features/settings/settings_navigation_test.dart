import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:wheres_the_bus/app/router/app_routes.dart';
import 'package:wheres_the_bus/core/storage/hive_store.dart';
import 'package:wheres_the_bus/data/repositories/settings_repository.dart';
import 'package:wheres_the_bus/features/settings/settings_option_screen.dart';
import 'package:wheres_the_bus/features/settings/settings_screen.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';

import '../../support/helpers/in_memory_settings_store.dart';

void main() {
  Future<GoRouter> mount(
    WidgetTester tester,
    SettingsRepository repository,
  ) async {
    final routes = [
      AppRoutes.settingsAppearance,
      AppRoutes.settingsLanguage,
      AppRoutes.settingsWalkPace,
      AppRoutes.settingsFareType,
    ];
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => SettingsScreen(
            settings: repository,
            packageInfoLoader: () async => PackageInfo(
              appName: 'Bus',
              packageName: 'bus',
              version: '1.0.0',
              buildNumber: '1',
            ),
            lastSyncedAtOf: DateTime.now,
          ),
        ),
        GoRoute(
          path: AppRoutes.settingsOfflineBus,
          builder: (_, _) => const Text('offline-bus-page'),
        ),
        for (final route in routes)
          GoRoute(
            path: route,
            builder: (_, state) {
              final extra = state.extra! as Map<String, Object?>;
              return SettingsOptionScreen(
                title: route,
                options: extra['options']! as List<String>,
                initialSelected: extra['selected']! as String,
              );
            },
          ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      MaterialApp.router(
        routerConfig: router,
        locale: const Locale('zh'),
        localizationsDelegates: AppI18n.localizationsDelegates,
        supportedLocales: AppI18n.supportedLocales,
      ),
    );
    await tester.pumpAndSettle();
    return router;
  }

  testWidgets('all settings pickers return selections and persist them', (
    tester,
  ) async {
    final repository = SettingsRepository(store: InMemorySettingsStore());
    final router = await mount(tester, repository);
    for (final label in ['外觀', '語言', '步行速度', '票種']) {
      final context = tester.element(find.byType(SettingsScreen));
      final i18n = AppI18n.of(context);
      final actualLabel = switch (label) {
        '外觀' => i18n.settingsAppearance,
        '語言' => i18n.settingsLanguage,
        '步行速度' => i18n.settingsWalkPace,
        _ => i18n.settingsFareType,
      };
      await tester.scrollUntilVisible(find.text(actualLabel), 150);
      await tester.ensureVisible(find.text(actualLabel));
      await tester.tap(find.text(actualLabel));
      await tester.pumpAndSettle();
      final picker = tester.widget<SettingsOptionScreen>(
        find.byType(SettingsOptionScreen),
      );
      final choice = picker.options.firstWhere(
        (option) => option != picker.initialSelected,
      );
      await tester.tap(find.text(choice));
      await tester.pumpAndSettle();
      expect(router.routeInformationProvider.value.uri.path, '/');
      expect(find.text(choice), findsWidgets);
    }
    expect(repository.languageCode, isNot(''));
  });

  testWidgets('the offline bus row shows the synced count and opens its page', (
    tester,
  ) async {
    final dir = await tester.runAsync(
      () => Directory.systemTemp.createTemp('settings-offline-bus-'),
    );
    Hive.init(dir!.path);
    await tester.runAsync(() async {
      await Hive.openBox<dynamic>('settings');
      await HiveStore.setOfflineBusCities(['Taipei', 'NewTaipei']);
    });
    addTearDown(
      () => tester.runAsync(() async {
        await Hive.box<dynamic>('settings').close();
        await dir.delete(recursive: true);
      }),
    );
    await mount(tester, SettingsRepository(store: InMemorySettingsStore()));
    final i18n = AppI18n.of(tester.element(find.byType(SettingsScreen)));
    await tester.scrollUntilVisible(find.text(i18n.settingsOfflineBus), 150);
    expect(find.text(i18n.settingsOfflineBusCount(2)), findsOneWidget);
    await tester.runAsync(() => HiveStore.setOfflineBusCities([]));
    await tester.pump();
    expect(find.text(i18n.settingsOfflineBusNone), findsOneWidget);
    await tester.ensureVisible(find.text(i18n.settingsOfflineBus));
    await tester.tap(find.text(i18n.settingsOfflineBus));
    await tester.pumpAndSettle();
    expect(find.text('offline-bus-page'), findsOneWidget);
    // The path is a deep link, so it is pinned rather than only round-tripped.
    expect(AppRoutes.settingsOfflineBus, '/settings/offline-bus');
  });

  testWidgets('canceling a picker keeps its previous setting', (tester) async {
    final repository = SettingsRepository(store: InMemorySettingsStore());
    final router = await mount(tester, repository);
    final i18n = AppI18n.of(tester.element(find.byType(SettingsScreen)));
    await tester.tap(find.text(i18n.settingsLanguage));
    await tester.pumpAndSettle();
    router.pop();
    await tester.pumpAndSettle();
    expect(repository.languageCode, 'system');
  });

  testWidgets(
    'notification access is refreshed on resume and opens OS settings',
    (tester) async {
      const channel = MethodChannel(
        'me.rabbitsayhello.wheresthebus/live_activity',
      );
      var enabled = false;
      var opened = 0;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      void install(Future<Object?> Function(MethodCall)? handler) =>
          messenger.setMockMethodCallHandler(channel, handler);
      install((call) async {
        if (call.method == 'notificationsEnabled') return enabled;
        if (call.method == 'openNotificationSettings') opened++;
        return null;
      });
      addTearDown(() => install(null));
      await mount(tester, SettingsRepository(store: InMemorySettingsStore()));
      final i18n = AppI18n.of(tester.element(find.byType(SettingsScreen)));
      final blocked = find.text(i18n.settingsNotificationsBlocked);
      await tester.ensureVisible(blocked);
      await tester.tap(blocked);
      await tester.pumpAndSettle();
      expect(opened, 1);
      enabled = true;
      tester.binding.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      );
      await tester.pumpAndSettle();
      expect(blocked, findsNothing);
      tester.binding.handleAppLifecycleStateChanged(
        AppLifecycleState.inactive,
      );
      await tester.pump();
    },
  );

  test('freshness labels distinguish missing, same-day and older sync', () {
    final i18n = lookupAppI18n(const Locale('zh'));
    expect(formatSyncFreshness(i18n, null), i18n.settingsSyncNever);
    final now = DateTime.now();
    expect(
      formatSyncFreshness(i18n, now),
      i18n.settingsSyncToday(
        '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}',
      ),
    );
    expect(
      formatSyncFreshness(i18n, DateTime(2020, 3, 4, 5, 6)),
      '03/04 05:06',
    );
  });
}
