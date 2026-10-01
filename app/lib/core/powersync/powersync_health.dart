import 'dart:async';

class PowerSyncHealth<T> {
  PowerSyncHealth({
    required this.errorOf,
    required this.onError,
    this.freshnessOf,
  });

  /// Extracts the current error (or `null` when healthy) from a status
  /// event.
  final Object? Function(T status) errorOf;

  /// Called with each newly observed, non-repeated error.
  final void Function(Object error) onError;

  /// Extracts the last-successful-sync timestamp from a status event, or
  /// `null` when the event carries no fresher timestamp (e.g. mid-download).
  /// Optional: services that don't need freshness tracking can omit it.
  final DateTime? Function(T status)? freshnessOf;

  StreamSubscription<T>? _subscription;
  String? _lastErrorKey;
  DateTime? _lastSyncedAt;

  /// Most recent successful-sync timestamp observed on the stream, or
  /// `null` if [freshnessOf] wasn't supplied or no sync has completed yet.
  DateTime? get lastSyncedAt => _lastSyncedAt;

  void listen(Stream<T> stream) {
    unawaited(_subscription?.cancel());
    _lastErrorKey = null;
    _subscription = stream.listen((status) {
      final freshness = freshnessOf;
      if (freshness != null) {
        final synced = freshness(status);
        if (synced != null) _lastSyncedAt = synced;
      }
      final error = errorOf(status);
      if (error == null) {
        _lastErrorKey = null;
        return;
      }
      final key = error.toString();
      if (key == _lastErrorKey) return;
      _lastErrorKey = key;
      onError(error);
    });
  }

  /// Cancels the owned subscription, if any. Call from `close()`/`dispose()`
  /// so a service teardown never leaves a dangling listener.
  Future<void> cancel() async {
    await _subscription?.cancel();
    _subscription = null;
    _lastErrorKey = null;
    _lastSyncedAt = null;
  }
}
