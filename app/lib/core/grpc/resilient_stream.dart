import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:grpc/grpc.dart';
import 'package:wheres_the_bus/core/errors/app_error.dart';
import 'package:wheres_the_bus/core/firebase/crash_reporter.dart';
import 'package:wheres_the_bus/core/lifecycle/app_foreground.dart';
import 'package:wheres_the_bus/core/lifecycle/app_network.dart';

typedef RetryDelay = Duration Function(Duration delay);

class ResilientSubscription<T> {
  ResilientSubscription({
    required Stream<T> Function() source,
    required void Function(T data) onData,
    required void Function(AppError error) onFailure,
    void Function()? onRecovered,
    int maxFailures = 5,
    Duration baseDelay = const Duration(seconds: 2),
    Duration maxDelay = const Duration(seconds: 30),
    Duration recoveryGrace = const Duration(seconds: 5),
    void Function(Object, StackTrace)? reportError,
    RetryDelay? retryDelay,
    ValueListenable<bool>? foreground,
    ValueListenable<bool>? online,
  }) : _source = source,
       _onData = onData,
       _onFailure = onFailure,
       _onRecovered = onRecovered,
       _maxFailures = maxFailures,
       _baseDelay = baseDelay,
       _maxDelay = maxDelay,
       _recoveryGrace = recoveryGrace,
       _reportError = reportError ?? CrashReporter.record,
       _retryDelay = retryDelay ?? _jitteredDelay,
       _foreground = foreground ?? AppForeground.value,
       _online = online ?? AppNetwork.online {
    _foreground.addListener(_onForegroundChanged);
    _online.addListener(_onOnlineChanged);
    if (_foreground.value) _listen();
  }

  final Stream<T> Function() _source;
  final void Function(T data) _onData;
  final void Function(AppError error) _onFailure;
  final void Function()? _onRecovered;
  final int _maxFailures;
  final Duration _baseDelay;
  final Duration _maxDelay;
  final Duration _recoveryGrace;
  final void Function(Object, StackTrace) _reportError;
  final RetryDelay _retryDelay;
  final ValueListenable<bool> _foreground;
  final ValueListenable<bool> _online;

  StreamSubscription<T>? _sub;
  Timer? _timer;
  Timer? _graceTimer;
  int _failures = 0;
  int _cleanCloses = 0;
  bool _notified = false;
  bool _closed = false;

  void _onForegroundChanged() {
    if (_closed) return;
    if (!_foreground.value) {
      _timer?.cancel();
      _timer = null;
      _graceTimer?.cancel();
      _graceTimer = null;
      unawaited(_sub?.cancel() ?? Future<void>.value());
      _sub = null;
      return;
    }
    if (_sub != null) return;
    _timer?.cancel();
    _timer = null;
    _failures = 0;
    _cleanCloses = 0;
    _listen();
  }

  void _onOnlineChanged() {
    if (_closed || !_online.value || !_foreground.value) return;
    if (_sub != null || _timer == null) return;
    _timer!.cancel();
    _timer = null;
    _listen();
  }

  void _listen() {
    if (_closed || !_foreground.value) return;
    final Stream<T> stream;
    try {
      stream = _source();
    } on Object catch (e, s) {
      _handleError(e, s);
      return;
    }
    _sub = stream.listen(
      (data) {
        _markRecovered();
        _cleanCloses = 0;
        _onData(data);
      },
      onError: _handleError,
      onDone: () {
        if (_closed) return;
        _sub = null;
        // A clean close only happens on a connection that was actually
        // established, so it proves the endpoint is reachable just as a frame
        // would.
        _markRecovered();
        if (_cleanCloses < 6) _cleanCloses++;
        var delay = _baseDelay * (1 << (_cleanCloses - 1));
        if (delay > _maxDelay) delay = _maxDelay;
        _timer = Timer(_retryDelay(delay), _listen);
      },
    );
    if (_failures > 0 || _notified) {
      _graceTimer?.cancel();
      _graceTimer = Timer(_recoveryGrace, _markRecovered);
    }
  }

  /// Clears the failure state and tells the caller, once, that the feed is
  /// healthy again. A no-op when nothing had failed.
  void _markRecovered() {
    _graceTimer?.cancel();
    _graceTimer = null;
    if (_failures == 0 && !_notified) return;
    _failures = 0;
    _notified = false;
    _onRecovered?.call();
  }

  void _handleError(Object e, StackTrace s) {
    _graceTimer?.cancel();
    _graceTimer = null;
    _reportError(e, s);
    final terminal = _isTerminal(e);
    _failures = terminal ? _maxFailures : _failures + 1;
    if (_failures >= _maxFailures && !_notified) {
      _notified = true;
      _onFailure(AppError.from(e));
    }
    if (terminal) {
      // No retry is scheduled, so the loop stops here — until the next resume
      // re-listens (see [_onForegroundChanged]).
      unawaited(_sub?.cancel() ?? Future<void>.value());
      _sub = null;
      return;
    }
    _scheduleRetry();
  }

  static bool _isTerminal(Object e) {
    if (e is! GrpcError) return false;
    return switch (e.code) {
      StatusCode.unauthenticated ||
      StatusCode.permissionDenied ||
      StatusCode.unimplemented => true,
      _ => false,
    };
  }

  void _scheduleRetry() {
    if (_closed) return;
    unawaited(_sub?.cancel() ?? Future<void>.value());
    _sub = null;
    final shift = _failures - 1 > 5 ? 5 : _failures - 1;
    var delay = _baseDelay * (1 << shift);
    if (delay > _maxDelay) delay = _maxDelay;
    _timer = Timer(_retryDelay(delay), _listen);
  }

  Future<void> cancel() async {
    _closed = true;
    _foreground.removeListener(_onForegroundChanged);
    _online.removeListener(_onOnlineChanged);
    _timer?.cancel();
    _graceTimer?.cancel();
    await _sub?.cancel();
  }

  static Duration _jitteredDelay(Duration delay) {
    final min = delay.inMilliseconds ~/ 2;
    final max = delay.inMilliseconds + min;
    return Duration(milliseconds: min + _random.nextInt(max - min + 1));
  }

  static final Random _random = Random();
}

/// A `foreground` that never goes false, for feeds behind the tracking card:
/// the card is read on the lock screen, where the app is never resumed, and
/// pausing the feed there freezes the card.
final ValueListenable<bool> alwaysForeground = ValueNotifier<bool>(true);

/// [source] as a single stream that survives drops: a broken or closed
/// connection (a server rollout ends every stream) is reopened with the same
/// backoff as [ResilientSubscription], and listeners see nothing of it. Only
/// sustained failure ([maxFailures] in a row) reaches them, as one error
/// event, so an `onError` fallback still fires for a real outage.
Stream<T> resilientStream<T>(
  Stream<T> Function() source, {
  int maxFailures = 5,
  Duration baseDelay = const Duration(seconds: 2),
  Duration maxDelay = const Duration(seconds: 30),
  void Function(Object, StackTrace)? reportError,
  ValueListenable<bool>? foreground,
  ValueListenable<bool>? online,
}) {
  ResilientSubscription<T>? sub;
  late final StreamController<T> controller;
  controller = StreamController<T>(
    onListen: () => sub = ResilientSubscription<T>(
      source: source,
      onData: controller.add,
      onFailure: controller.addError,
      maxFailures: maxFailures,
      baseDelay: baseDelay,
      maxDelay: maxDelay,
      reportError: reportError,
      foreground: foreground,
      online: online,
    ),
    onCancel: () => sub?.cancel(),
  );
  return controller.stream;
}
