import 'package:equatable/equatable.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:wheres_the_bus/data/models/fare_type.dart';
import 'package:wheres_the_bus/data/repositories/settings_repository.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';

/// Appearance options shown in the settings picker.
///
/// [key] is the value persisted through [SettingsRepository.appearanceMode].
enum Appearance {
  system('system'),
  light('light'),
  dark('dark');

  const Appearance(this.key);
  final String key;

  static Appearance fromKey(String key) =>
      values.firstWhere((e) => e.key == key, orElse: () => system);

  String labelOf(AppI18n i18n) => switch (this) {
    Appearance.system => i18n.settingsFollowSystem,
    Appearance.light => i18n.appearanceLight,
    Appearance.dark => i18n.appearanceDark,
  };
}

enum Language {
  system('system'),
  zh('zh'),
  zhCn('zh_CN'),
  en('en');

  const Language(this.key);
  final String key;

  static Language fromKey(String? key) =>
      values.firstWhere((e) => e.key == key, orElse: () => system);

  /// What `MaterialApp.locale` should be set to. Null for [system] — that is
  /// the value that hands resolution back to the device's locale list, not a
  /// missing answer.
  Locale? get locale => switch (this) {
    Language.system => null,
    Language.zhCn => const Locale('zh', 'CN'),
    _ => Locale(key),
  };

  /// Every real language is named in itself — a rider looking for English
  /// should find "English", not its name in a language they don't read — so
  /// only [system] follows the current locale.
  String labelOf(AppI18n i18n) => switch (this) {
    Language.system => i18n.settingsFollowSystem,
    Language.zh => i18n.languageZh,
    Language.zhCn => i18n.languageZhCn,
    Language.en => i18n.languageEn,
  };
}

enum WalkPace {
  slower(100),
  standard(0),
  faster(180);

  const WalkPace(this.cmPerSec);
  final int cmPerSec;

  static WalkPace fromCmPerSec(int value) =>
      values.firstWhere((e) => e.cmPerSec == value, orElse: () => standard);

  String labelOf(AppI18n i18n) => switch (this) {
    WalkPace.slower => i18n.settingsWalkPaceSlower,
    WalkPace.standard => i18n.settingsWalkPaceStandard,
    WalkPace.faster => i18n.settingsWalkPaceFaster,
  };
}

enum UpdateCheck { idle, checking, upToDate, available, failed }

class SettingsState extends Equatable {
  const SettingsState({
    this.appearance = Appearance.system,
    this.language = Language.system,
    this.pushEnabled = true,
    this.pushUpdating = false,
    this.fareType = FareType.full,
    this.liveActivityEnabled = true,
    this.shakeToReport = true,
    this.stepFreeRouting = false,
    this.walkPace = WalkPace.standard,
    this.appVersion = '',
    this.powerSyncLastSyncedAt,
    this.updateCheck = UpdateCheck.idle,
    this.latestVersion = '',
  });

  final Appearance appearance;
  final Language language;
  final bool pushEnabled;
  final bool pushUpdating;

  /// The rider's ticket type, applied to every fare the app quotes.
  final FareType fareType;
  final bool liveActivityEnabled;

  /// Whether shaking the phone offers to open the report form.
  final bool shakeToReport;

  /// Whether the planner must route step-free. A fact about the rider, so it
  /// is set once here rather than per journey.
  final bool stepFreeRouting;

  /// The rider's usual walking pace, applied to every plan.
  final WalkPace walkPace;

  /// Real running-app version from `PackageInfo`, empty until it loads
  /// (F46). Never hardcoded.
  final String appVersion;

  /// Real PowerSync freshness, null until it loads or before the first sync
  /// completes (F46). Never hardcoded.
  final DateTime? powerSyncLastSyncedAt;

  /// Outcome of the last explicit 檢查更新 tap.
  final UpdateCheck updateCheck;

  /// The published version [updateCheck] found, empty in every state but
  /// [UpdateCheck.available].
  final String latestVersion;

  SettingsState copyWith({
    Appearance? appearance,
    Language? language,
    bool? pushEnabled,
    bool? pushUpdating,
    bool? largeText,
    FareType? fareType,
    bool? liveActivityEnabled,
    bool? shakeToReport,
    bool? stepFreeRouting,
    WalkPace? walkPace,
    String? appVersion,
    DateTime? powerSyncLastSyncedAt,
    UpdateCheck? updateCheck,
    String? latestVersion,
  }) => SettingsState(
    appearance: appearance ?? this.appearance,
    language: language ?? this.language,
    pushEnabled: pushEnabled ?? this.pushEnabled,
    pushUpdating: pushUpdating ?? this.pushUpdating,
    fareType: fareType ?? this.fareType,
    liveActivityEnabled: liveActivityEnabled ?? this.liveActivityEnabled,
    shakeToReport: shakeToReport ?? this.shakeToReport,
    stepFreeRouting: stepFreeRouting ?? this.stepFreeRouting,
    walkPace: walkPace ?? this.walkPace,
    appVersion: appVersion ?? this.appVersion,
    powerSyncLastSyncedAt: powerSyncLastSyncedAt ?? this.powerSyncLastSyncedAt,
    updateCheck: updateCheck ?? this.updateCheck,
    latestVersion: latestVersion ?? this.latestVersion,
  );

  @override
  List<Object?> get props => [
    appearance,
    language,
    pushEnabled,
    pushUpdating,
    fareType,
    liveActivityEnabled,
    shakeToReport,
    stepFreeRouting,
    walkPace,
    appVersion,
    powerSyncLastSyncedAt,
    updateCheck,
    latestVersion,
  ];
}
