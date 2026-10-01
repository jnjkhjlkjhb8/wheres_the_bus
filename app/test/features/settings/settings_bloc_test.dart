import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:wheres_the_bus/data/repositories/settings_repository.dart';
import 'package:wheres_the_bus/features/settings/bloc/settings_bloc.dart';
import 'package:wheres_the_bus/features/settings/bloc/settings_event.dart';
import 'package:wheres_the_bus/features/settings/bloc/settings_state.dart';

import '../../support/helpers/in_memory_settings_store.dart';

Future<bool> _grant({required bool requested}) async => requested;

Future<PackageInfo> _fakePackageInfo({String version = '2.4.1'}) async =>
    PackageInfo(
      appName: 'wheres_the_bus',
      packageName: 'tw.gov.bus',
      version: version,
      buildNumber: '1',
    );

void main() {
  SettingsRepository repo([Map<String, Object?>? initial]) =>
      SettingsRepository(store: InMemorySettingsStore(initial));

  SettingsBloc build({
    SettingsRepository? settings,
    PushUpdater? updatePushPreference,
    Future<PackageInfo> Function()? packageInfoLoader,
    DateTime? Function()? lastSyncedAtOf,
    Future<bool> Function()? refreshConfig,
    String Function()? latestVersionOf,
  }) {
    final bloc = SettingsBloc(
      settings: settings ?? repo(),
      updatePushPreference: updatePushPreference ?? _grant,
      packageInfoLoader: packageInfoLoader ?? _fakePackageInfo,
      lastSyncedAtOf: lastSyncedAtOf ?? () => null,
      refreshConfig: refreshConfig ?? () async => true,
      latestVersionOf: latestVersionOf ?? () => '2.4.1',
    );
    addTearDown(bloc.close);
    return bloc;
  }

  group('initial load', () {
    test('reads defaults from an empty repository', () {
      final bloc = build();
      expect(bloc.state.appearance, Appearance.system);
      expect(bloc.state.language, Language.system);
      expect(bloc.state.pushEnabled, isTrue);
      expect(bloc.state.pushUpdating, isFalse);
      expect(bloc.state.liveActivityEnabled, isTrue);
      expect(bloc.state.appVersion, isEmpty);
      expect(bloc.state.powerSyncLastSyncedAt, isNull);
    });

    test('loads the real app version from PackageInfo (F46)', () async {
      final bloc = build(
        packageInfoLoader: () => _fakePackageInfo(version: '3.2.1'),
      );
      await bloc.stream.first;

      expect(bloc.state.appVersion, '3.2.1');
    });

    test('loads real PowerSync freshness (F46)', () async {
      final synced = DateTime.utc(2026, 7, 16, 6);
      final bloc = build(lastSyncedAtOf: () => synced);
      await bloc.stream.first;

      expect(bloc.state.powerSyncLastSyncedAt, synced);
    });

    test('falls back to empty metadata when loaders throw', () async {
      final bloc = build(
        packageInfoLoader: () async => throw Exception('boom'),
        lastSyncedAtOf: () => throw Exception('boom'),
      );
      await bloc.stream.first;

      expect(bloc.state.appVersion, isEmpty);
      expect(bloc.state.powerSyncLastSyncedAt, isNull);
    });

    test('hydrates from persisted values', () {
      final bloc = build(
        settings: repo({
          'appearance_mode': 'dark',
          'push_enabled': false,
          'large_text': true,
          'live_activity_enabled': false,
        }),
      );
      expect(bloc.state.appearance, Appearance.dark);
      expect(bloc.state.pushEnabled, isFalse);
      expect(bloc.state.liveActivityEnabled, isFalse);
    });
  });

  group('setting changes persist', () {
    test('appearance selection persists the key', () async {
      final settings = repo();
      final bloc = build(settings: settings)
        ..add(const AppearanceSelected(Appearance.dark));
      await bloc.stream.first;

      expect(bloc.state.appearance, Appearance.dark);
      expect(settings.appearanceMode, 'dark');
    });

    test('live activity toggle persists', () async {
      final settings = repo();
      final bloc = build(settings: settings)
        ..add(const LiveActivityToggled(value: false));
      await bloc.stream.first;

      expect(bloc.state.liveActivityEnabled, isFalse);
      expect(settings.liveActivityEnabled, isFalse);
    });
  });

  group('push toggle', () {
    test('reconciles to the granted permission and clears updating', () async {
      final settings = repo();
      final bloc = build(
        settings: settings,
        updatePushPreference: ({required requested}) async => true,
      );

      final states = <SettingsState>[];
      final sub = bloc.stream.listen(states.add);
      addTearDown(sub.cancel);

      bloc.add(const PushToggled(value: true));
      await Future<void>.delayed(const Duration(milliseconds: 10));

      // Optimistic pushUpdating=true, then settled pushUpdating=false.
      expect(states.first.pushUpdating, isTrue);
      expect(bloc.state.pushUpdating, isFalse);
      expect(bloc.state.pushEnabled, isTrue);
      expect(settings.pushEnabled, isTrue);
    });

    test('falls back to disabled when the request is denied', () async {
      final settings = repo();
      final bloc = build(
        settings: settings,
        updatePushPreference: ({required requested}) async => false,
      )..add(const PushToggled(value: true));

      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(bloc.state.pushEnabled, isFalse);
      expect(bloc.state.pushUpdating, isFalse);
      expect(settings.pushEnabled, isFalse);
    });

    test('falls back to disabled when the updater throws', () async {
      final settings = repo();
      final bloc = build(
        settings: settings,
        updatePushPreference: ({required requested}) async =>
            throw Exception('denied'),
      )..add(const PushToggled(value: true));

      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(bloc.state.pushEnabled, isFalse);
      expect(bloc.state.pushUpdating, isFalse);
      expect(settings.pushEnabled, isFalse);
    });
  });

  group('檢查更新', () {
    /// Builds a bloc whose app version has already settled, since the check
    /// compares against it and the loader resolves asynchronously.
    Future<SettingsBloc> ready({
      Future<bool> Function()? refreshConfig,
      String Function()? latestVersionOf,
      Future<PackageInfo> Function()? packageInfoLoader,
    }) async {
      final bloc = build(
        refreshConfig: refreshConfig,
        latestVersionOf: latestVersionOf,
        packageInfoLoader: packageInfoLoader,
      );
      await bloc.stream.first;
      return bloc;
    }

    test('a published newer build is offered', () async {
      final bloc = await ready(latestVersionOf: () => '2.5.0');
      bloc.add(const UpdateCheckRequested());
      await bloc.stream.firstWhere(
        (s) => s.updateCheck != UpdateCheck.checking,
      );

      expect(bloc.state.updateCheck, UpdateCheck.available);
      expect(bloc.state.latestVersion, '2.5.0');
    });

    test('the running build being current reports up to date', () async {
      final bloc = await ready(latestVersionOf: () => '2.4.1');
      bloc.add(const UpdateCheckRequested());
      await bloc.stream.firstWhere(
        (s) => s.updateCheck != UpdateCheck.checking,
      );

      expect(bloc.state.updateCheck, UpdateCheck.upToDate);
      expect(bloc.state.latestVersion, isEmpty);
    });

    test('a failed refresh never reports up to date', () async {
      // Offline, or Firebase off. Claiming "已是最新版本" off a stale read
      // would be a lie told to the one rider who explicitly asked.
      final bloc = await ready(
        refreshConfig: () async => false,
        latestVersionOf: () => '2.5.0',
      );
      bloc.add(const UpdateCheckRequested());
      await bloc.stream.firstWhere(
        (s) => s.updateCheck != UpdateCheck.checking,
      );

      expect(bloc.state.updateCheck, UpdateCheck.failed);
      expect(bloc.state.latestVersion, isEmpty);
    });

    test('an unknown running version cannot answer', () async {
      final bloc = await ready(
        packageInfoLoader: () async => throw Exception('boom'),
        latestVersionOf: () => '2.5.0',
      );
      bloc.add(const UpdateCheckRequested());
      await bloc.stream.firstWhere(
        (s) => s.updateCheck != UpdateCheck.checking,
      );

      expect(bloc.state.updateCheck, UpdateCheck.failed);
    });

    test('a second tap while in flight is ignored', () async {
      var refreshes = 0;
      final gate = Completer<void>();
      final bloc = await ready(
        refreshConfig: () async {
          refreshes++;
          await gate.future;
          return true;
        },
        latestVersionOf: () => '2.5.0',
      );

      bloc
        ..add(const UpdateCheckRequested())
        ..add(const UpdateCheckRequested());
      await bloc.stream.firstWhere(
        (s) => s.updateCheck == UpdateCheck.checking,
      );
      gate.complete();
      await bloc.stream.firstWhere(
        (s) => s.updateCheck != UpdateCheck.checking,
      );

      expect(refreshes, 1);
    });
  });
}
