import 'package:flutter/material.dart' show Locale, ThemeMode;
import 'package:wheres_the_bus/core/storage/hive_store.dart';
import 'package:wheres_the_bus/data/models/fare_type.dart';

abstract interface class SettingsStore {
  Object? get(String key, {Object? defaultValue});
  Future<void> put(String key, Object? value);
  bool get ready;
}

class SettingsRepository {
  SettingsRepository({SettingsStore? store})
    : _store = store ?? const _HiveSettingsStore();

  static final SettingsRepository instance = SettingsRepository();

  final SettingsStore _store;

  bool _boolValue(String key, {required bool defaultValue}) =>
      _store.get(key, defaultValue: defaultValue) as bool? ?? defaultValue;

  bool get liveActivityEnabled =>
      !_store.ready || _boolValue('live_activity_enabled', defaultValue: true);
  set liveActivityEnabled(bool value) =>
      _store.put('live_activity_enabled', value);

  bool get shakeToReport =>
      !_store.ready || _boolValue(shakeToReportKey, defaultValue: true);
  set shakeToReport(bool value) => _store.put(shakeToReportKey, value);

  /// Settings-box key behind [shakeToReport]. Exposed so the shake listener
  /// can watch this key alone and attach or drop the accelerometer stream the
  /// instant the rider flips the switch.
  static const String shakeToReportKey = 'shake_to_report';

  /// The rider's own ticket type, applied to every fare the app quotes. Read
  /// on every fare render (bus and rail), so it is guarded on
  /// [SettingsStore.ready] the same way [appearanceMode] is.
  FareType get fareType => _store.ready
      ? FareType.fromKey(_store.get(fareTypeKey) as String?)
      : FareType.full;
  set fareType(FareType value) => _store.put(fareTypeKey, value.key);

  /// Settings-box key behind [fareType]. Exposed so fare widgets can listen to
  /// this key alone and re-render the instant the preference changes, instead
  /// of showing the old ticket type until the screen is rebuilt.
  static const String fareTypeKey = 'fare_type';

  bool get stepFreeRouting =>
      _boolValue(stepFreeRoutingKey, defaultValue: false);
  set stepFreeRouting(bool value) => _store.put(stepFreeRoutingKey, value);

  static const String stepFreeRoutingKey = 'step_free_routing';

  int get walkSpeedCmPerSec =>
      _store.get(walkSpeedKey, defaultValue: 0) as int? ?? 0;
  set walkSpeedCmPerSec(int value) => _store.put(walkSpeedKey, value);

  static const String walkSpeedKey = 'walk_speed_cm_per_sec';

  /// Persisted appearance preference: 'system', 'light', or 'dark'.
  /// Guarded on [SettingsStore.ready] so it is safe to read before the box
  /// opens (the pre-init splash reads it and must not throw).
  String get appearanceMode => _store.ready
      ? (_store.get('appearance_mode', defaultValue: 'system') as String? ??
            'system')
      : 'system';
  set appearanceMode(String value) => _store.put('appearance_mode', value);

  ThemeMode get themeMode => switch (appearanceMode) {
    'light' => ThemeMode.light,
    'dark' => ThemeMode.dark,
    _ => ThemeMode.system,
  };

  /// Persisted language preference: 'system', 'zh', 'zh_CN' or 'en'. Guarded on
  /// [SettingsStore.ready] like [appearanceMode] — it is read while building
  /// the root `MaterialApp`, which can happen before the box opens.
  String get languageCode => _store.ready
      ? (_store.get(languageKey, defaultValue: 'system') as String? ?? 'system')
      : 'system';
  set languageCode(String value) => _store.put(languageKey, value);

  /// Settings-box key behind [languageCode]. Exposed so the root app can
  /// listen on this key alone and re-resolve the locale the instant the
  /// rider picks a language, with no restart.
  static const String languageKey = 'language';

  /// Locale for `MaterialApp.locale`. Null is the answer for 'system', not a
  /// missing one: it is what hands resolution back to the device.
  Locale? get locale => switch (languageCode) {
    'zh' => const Locale('zh'),
    'zh_CN' => const Locale('zh', 'CN'),
    'en' => const Locale('en'),
    _ => null,
  };

  bool get pushEnabled => _boolValue('push_enabled', defaultValue: true);
  set pushEnabled(bool value) => _store.put('push_enabled', value);

  List<String> get favMetroStations => List<String>.from(
    _store.get('fav_metro_stations', defaultValue: const <String>[]) as List? ??
        const <String>[],
  );
  set favMetroStations(List<String> list) =>
      _store.put('fav_metro_stations', list);

  /// Set of alert message keys the user has already read.
  Set<String> readAlerts() {
    if (!_store.ready) return {};
    final list =
        _store.get('read_alerts', defaultValue: const <String>[]) as List? ??
        const <String>[];
    return {...list.cast<String>()};
  }

  Future<void> setReadAlerts(Set<String> read) {
    if (!_store.ready) return Future<void>.value();
    return _store.put('read_alerts', read.toList());
  }
}

/// Hive-backed [SettingsStore] over the shared settings box.
class _HiveSettingsStore implements SettingsStore {
  const _HiveSettingsStore();

  @override
  bool get ready => HiveStore.settingsReady;

  @override
  Object? get(String key, {Object? defaultValue}) =>
      HiveStore.settings.get(key, defaultValue: defaultValue);

  @override
  Future<void> put(String key, Object? value) =>
      HiveStore.settings.put(key, value);
}
