import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/models/fare_type.dart';
import 'package:wheres_the_bus/data/repositories/settings_repository.dart';

import '../../support/helpers/in_memory_settings_store.dart';

class UnopenedStore implements SettingsStore {
  @override
  bool get ready => false;
  @override
  Object? get(String key, {Object? defaultValue}) =>
      throw StateError('unopened');
  @override
  Future<void> put(String key, Object? value) => throw StateError('unopened');
}

void main() {
  test('pre-init reads use defaults without opening the store', () async {
    final repo = SettingsRepository(store: UnopenedStore());
    expect(repo.fareType, FareType.full);
    expect(repo.shakeToReport, isTrue);
    expect(repo.languageCode, 'system');
    expect(repo.appearanceMode, 'system');
    expect(repo.locale, isNull);
    expect(repo.themeMode, ThemeMode.system);
    expect(repo.readAlerts(), isEmpty);
    await repo.setReadAlerts({'unused'});
  });

  test(
    'persisted nullable preferences fall back and typed values round-trip',
    () {
      final store = InMemorySettingsStore({
        SettingsRepository.fareTypeKey: null,
        SettingsRepository.shakeToReportKey: null,
        SettingsRepository.languageKey: null,
        'appearance_mode': null,
      });
      final repo = SettingsRepository(store: store);
      expect(repo.fareType, FareType.full);
      expect(repo.shakeToReport, isTrue);
      expect(repo.languageCode, 'system');
      expect(repo.appearanceMode, 'system');
      for (final type in FareType.values) {
        repo.fareType = type;
        expect(repo.fareType, type);
      }
      repo.shakeToReport = false;
      expect(repo.shakeToReport, isFalse);
      repo.languageCode = 'zh_CN';
      expect(repo.locale, const Locale('zh', 'CN'));
      repo.languageCode = 'en';
      expect(repo.locale, const Locale('en'));
      repo.languageCode = 'zh';
      expect(repo.locale, const Locale('zh'));
      repo.languageCode = 'unknown';
      expect(repo.locale, isNull);
      repo.appearanceMode = 'light';
      expect(repo.themeMode, ThemeMode.light);
      repo.appearanceMode = 'dark';
      expect(repo.themeMode, ThemeMode.dark);
      repo.appearanceMode = 'unknown';
      expect(repo.themeMode, ThemeMode.system);
    },
  );

  SettingsRepository build([Map<String, Object?>? initial]) =>
      SettingsRepository(store: InMemorySettingsStore(initial));

  test('bool settings default to their documented values', () {
    final repo = build();
    expect(repo.liveActivityEnabled, isTrue);
    expect(repo.pushEnabled, isTrue);
  });

  test('bool settings round-trip through the store', () {
    final repo = build()..liveActivityEnabled = false;
    expect(repo.liveActivityEnabled, isFalse);
  });

  test('favMetroStations round-trips a list', () {
    final repo = build();
    expect(repo.favMetroStations, isEmpty);
    repo.favMetroStations = ['BL01', 'R02'];
    expect(repo.favMetroStations, ['BL01', 'R02']);
  });

  test('read alerts round-trip and start empty', () async {
    final repo = build();
    expect(repo.readAlerts(), isEmpty);
    await repo.setReadAlerts({'a', 'b'});
    expect(repo.readAlerts(), {'a', 'b'});
  });
}
