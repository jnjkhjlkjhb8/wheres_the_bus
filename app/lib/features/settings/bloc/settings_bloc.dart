import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:wheres_the_bus/core/firebase/firebase_bootstrap.dart';
import 'package:wheres_the_bus/core/firebase/remote_config.dart';
import 'package:wheres_the_bus/core/powersync/powersync_service.dart';
import 'package:wheres_the_bus/core/update/update_status.dart';
import 'package:wheres_the_bus/data/repositories/settings_repository.dart';
import 'package:wheres_the_bus/features/settings/bloc/settings_event.dart';
import 'package:wheres_the_bus/features/settings/bloc/settings_state.dart';

/// Applies the requested push preference and returns the effective state.
typedef PushUpdater = Future<bool> Function({required bool requested});

class SettingsBloc extends Bloc<SettingsEvent, SettingsState> {
  SettingsBloc({
    SettingsRepository? settings,
    PushUpdater? updatePushPreference,
    Future<PackageInfo> Function()? packageInfoLoader,
    DateTime? Function()? lastSyncedAtOf,
    Future<bool> Function()? refreshConfig,
    String Function()? latestVersionOf,
  }) : this._(
         settings ?? SettingsRepository.instance,
         updatePushPreference ?? FirebaseBootstrap.updatePushPreference,
         packageInfoLoader ?? PackageInfo.fromPlatform,
         lastSyncedAtOf ?? (() => PowerSyncService.instance.lastSyncedAt),
         refreshConfig ?? AppConfig.refresh,
         latestVersionOf ?? (() => AppConfig.getString('latest_version')),
       );

  SettingsBloc._(
    this._settings,
    this._updatePush,
    this._packageInfoLoader,
    this._lastSyncedAtOf,
    this._refreshConfig,
    this._latestVersionOf,
  ) : super(_initialState(_settings)) {
    on<AppearanceSelected>(_onAppearanceSelected);
    on<LanguageSelected>(_onLanguageSelected);
    on<FareTypeSelected>(_onFareTypeSelected);
    on<LiveActivityToggled>(_onLiveActivityToggled);
    on<ShakeToReportToggled>(_onShakeToReportToggled);
    on<StepFreeRoutingToggled>(_onStepFreeRoutingToggled);
    on<WalkPaceSelected>(_onWalkPaceSelected);
    on<PushToggled>(_onPushToggled);
    on<UpdateCheckRequested>(_onUpdateCheckRequested);
    on<AppMetadataLoaded>(_onAppMetadataLoaded);
    unawaited(_loadMetadata());
  }

  final SettingsRepository _settings;
  final PushUpdater _updatePush;
  final Future<PackageInfo> Function() _packageInfoLoader;
  final DateTime? Function() _lastSyncedAtOf;
  final Future<bool> Function() _refreshConfig;
  final String Function() _latestVersionOf;

  Future<void> _loadMetadata() async {
    var version = '';
    try {
      version = (await _packageInfoLoader()).version;
    } on Object catch (_) {
      // Leave the row blank rather than showing a stale/fake version.
    }
    DateTime? lastSyncedAt;
    try {
      lastSyncedAt = _lastSyncedAtOf();
    } on Object catch (_) {
      // PowerSync not initialized yet, or unavailable in this test/build.
    }
    if (!isClosed) {
      add(
        AppMetadataLoaded(
          appVersion: version,
          powerSyncLastSyncedAt: lastSyncedAt,
        ),
      );
    }
  }

  void _onAppMetadataLoaded(
    AppMetadataLoaded e,
    Emitter<SettingsState> emit,
  ) {
    emit(
      state.copyWith(
        appVersion: e.appVersion,
        powerSyncLastSyncedAt: e.powerSyncLastSyncedAt,
      ),
    );
  }

  static SettingsState _initialState(SettingsRepository s) => SettingsState(
    appearance: Appearance.fromKey(s.appearanceMode),
    language: Language.fromKey(s.languageCode),
    pushEnabled: s.pushEnabled,
    fareType: s.fareType,
    liveActivityEnabled: s.liveActivityEnabled,
    shakeToReport: s.shakeToReport,
    stepFreeRouting: s.stepFreeRouting,
    walkPace: WalkPace.fromCmPerSec(s.walkSpeedCmPerSec),
  );

  void _onAppearanceSelected(
    AppearanceSelected e,
    Emitter<SettingsState> emit,
  ) {
    _settings.appearanceMode = e.appearance.key;
    emit(state.copyWith(appearance: e.appearance));
  }

  /// Writes through to the settings box before emitting: the root app listens
  /// on [SettingsRepository.languageKey] and re-resolves the locale from that
  /// write, so the whole UI switches language on the same frame as the row.
  void _onLanguageSelected(LanguageSelected e, Emitter<SettingsState> emit) {
    _settings.languageCode = e.language.key;
    emit(state.copyWith(language: e.language));
  }

  // Both of these are read when a plan is built, not watched, so the write
  // is what the next search picks up; the emit only updates the row.
  void _onStepFreeRoutingToggled(
    StepFreeRoutingToggled e,
    Emitter<SettingsState> emit,
  ) {
    _settings.stepFreeRouting = e.value;
    emit(state.copyWith(stepFreeRouting: e.value));
  }

  void _onWalkPaceSelected(WalkPaceSelected e, Emitter<SettingsState> emit) {
    _settings.walkSpeedCmPerSec = e.pace.cmPerSec;
    emit(state.copyWith(walkPace: e.pace));
  }

  void _onFareTypeSelected(FareTypeSelected e, Emitter<SettingsState> emit) {
    // Fare widgets read the persisted value through a Hive listenable rather
    // than this bloc, so the write is what re-renders them — this emit only
    // updates the settings row itself.
    _settings.fareType = e.fareType;
    emit(state.copyWith(fareType: e.fareType));
  }

  void _onLiveActivityToggled(
    LiveActivityToggled e,
    Emitter<SettingsState> emit,
  ) {
    _settings.liveActivityEnabled = e.value;
    emit(state.copyWith(liveActivityEnabled: e.value));
  }

  /// The write is what matters: the shake listener watches the settings box on
  /// this key and attaches or drops the accelerometer stream from it, so the
  /// emit below only updates the row itself.
  void _onShakeToReportToggled(
    ShakeToReportToggled e,
    Emitter<SettingsState> emit,
  ) {
    _settings.shakeToReport = e.value;
    emit(state.copyWith(shakeToReport: e.value));
  }

  Future<void> _onPushToggled(
    PushToggled e,
    Emitter<SettingsState> emit,
  ) async {
    if (state.pushUpdating) return;
    // Persist optimistically, then reconcile with the platform's effective
    // permission once the async request settles.
    _settings.pushEnabled = e.value;
    emit(state.copyWith(pushEnabled: e.value, pushUpdating: true));
    var enabled = false;
    try {
      enabled = await _updatePush(requested: e.value);
    } on Object catch (_) {
      enabled = false;
    } finally {
      _settings.pushEnabled = enabled;
      if (!isClosed) {
        emit(state.copyWith(pushEnabled: enabled, pushUpdating: false));
      }
    }
  }

  Future<void> _onUpdateCheckRequested(
    UpdateCheckRequested e,
    Emitter<SettingsState> emit,
  ) async {
    if (state.updateCheck == UpdateCheck.checking) return;
    emit(state.copyWith(updateCheck: UpdateCheck.checking));
    final refreshed = await _refreshConfig();
    final current = state.appVersion;
    // No fresh fetch, or no version to compare, means no answer. Say that
    // rather than reporting the stale read as a clean bill of health.
    if (!refreshed || current.isEmpty) {
      emit(state.copyWith(updateCheck: UpdateCheck.failed, latestVersion: ''));
      return;
    }
    final latest = _latestVersionOf();
    emit(
      isBelowVersion(current, latest)
          ? state.copyWith(
              updateCheck: UpdateCheck.available,
              latestVersion: latest,
            )
          : state.copyWith(
              updateCheck: UpdateCheck.upToDate,
              latestVersion: '',
            ),
    );
  }
}
