import 'dart:async';

import 'package:flutter/foundation.dart';

enum AppBootstrapState { initializing, ready, degraded, failed }

enum AppBootstrapFailurePhase { storage, network }

class AppBootstrapController extends ChangeNotifier {
  AppBootstrapController({
    required Future<void> Function() initHive,
    required Future<void> Function() initGrpc,
    required Future<void> Function() initFirebase,
    required Future<void> Function() initPowerSync,
  }) : _initHive = initHive,
       _initGrpc = initGrpc,
       _initFirebase = initFirebase,
       _initPowerSync = initPowerSync;

  final Future<void> Function() _initHive;
  final Future<void> Function() _initGrpc;
  final Future<void> Function() _initFirebase;
  final Future<void> Function() _initPowerSync;

  AppBootstrapState _state = AppBootstrapState.initializing;
  AppBootstrapState get state => _state;

  /// The error from the most recent failed essential-init attempt, if any.
  Object? lastError;

  /// Which essential step [lastError] came from. Null whenever [lastError]
  /// is null.
  AppBootstrapFailurePhase? lastErrorPhase;

  bool _bestEffortFailed = false;

  Future<void> start() async {
    unawaited(_runBestEffort(_initFirebase, 'firebase'));
    await _runEssential();
    unawaited(_runBestEffort(_initPowerSync, 'powersync'));
  }

  Future<void> retry() => _runEssential();

  Future<void> _runEssential() async {
    _setState(AppBootstrapState.initializing);
    final results = await Future.wait([
      _guardEssential(_initHive, AppBootstrapFailurePhase.storage),
      _guardEssential(_initGrpc, AppBootstrapFailurePhase.network),
    ]);
    for (final result in results) {
      if (result.error == null) continue;
      lastError = result.error;
      lastErrorPhase = result.phase;
      _setState(AppBootstrapState.failed);
      return;
    }
    lastError = null;
    lastErrorPhase = null;
    _setState(
      _bestEffortFailed ? AppBootstrapState.degraded : AppBootstrapState.ready,
    );
  }

  Future<({Object? error, AppBootstrapFailurePhase? phase})> _guardEssential(
    Future<void> Function() step,
    AppBootstrapFailurePhase phase,
  ) async {
    try {
      await step();
      return (error: null, phase: null);
    } on Object catch (error) {
      return (error: error, phase: phase);
    }
  }

  Future<void> _runBestEffort(
    Future<void> Function() step,
    String label,
  ) async {
    try {
      await step();
    } on Object catch (error) {
      _bestEffortFailed = true;
      debugPrint('[bootstrap] $label failed (best-effort, degraded): $error');
      if (_state == AppBootstrapState.ready) {
        _setState(AppBootstrapState.degraded);
      }
    }
  }

  void _setState(AppBootstrapState next) {
    if (_state == next) return;
    _state = next;
    notifyListeners();
  }
}
