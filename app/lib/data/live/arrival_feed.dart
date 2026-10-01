import 'dart:async';

import 'package:wheres_the_bus/core/errors/app_error.dart';
import 'package:wheres_the_bus/core/grpc/resilient_stream.dart';

/// Merges a fresh server frame into the current list, returning the next list.
/// Returning the same instance as `current` signals "no change" so the feed
/// skips the emission (e.g. an empty replace frame while entries exist).
typedef _Merge<T> = List<T> Function(List<T> current, List<T> frame);

enum ArrivalFeedEmissionKind { source, decay }

/// One `ArrivalFeed.watch` emission: the merged/decayed arrival list plus
/// which kind of event produced it. See [ArrivalFeedEmissionKind] for what
/// each kind means to a consumer.
class ArrivalFeedEmission<T> {
  const ArrivalFeedEmission(this.arrivals, this.kind);

  final List<T> arrivals;
  final ArrivalFeedEmissionKind kind;

  bool get isSource => kind == ArrivalFeedEmissionKind.source;
  bool get isDecay => kind == ArrivalFeedEmissionKind.decay;
}

class ArrivalFeed<T> {
  ArrivalFeed._({
    required _Merge<T> merge,
    required T Function(T item, DateTime now)? decay,
    required Duration decayInterval,
  }) : _merge = merge,
       _decay = decay,
       _decayInterval = decayInterval;

  factory ArrivalFeed.replace({
    T Function(T item, DateTime now)? decay,
    int Function(T a, T b)? compare,
    Duration decayInterval = const Duration(seconds: 15),
  }) => ArrivalFeed._(
    merge: (current, frame) {
      // Empty-frame guard: keep the last good list when a frame arrives empty
      // but entries already exist. Mirrors the bus blocs' original _onUpdated.
      if (frame.isEmpty && current.isNotEmpty) return current;
      if (compare == null) return frame;
      return [...frame]..sort(compare);
    },
    decay: decay,
    decayInterval: decayInterval,
  );

  factory ArrivalFeed.upsertByKey({
    required Object Function(T item) key,
    required int Function(T a, T b) compare,
    T Function(T item, DateTime now)? decay,
    Duration decayInterval = const Duration(seconds: 15),
  }) => ArrivalFeed._(
    merge: (current, frame) {
      if (frame.isEmpty) return current;
      final byKey = {for (final item in current) key(item): item};
      for (final item in frame) {
        byKey[key(item)] = item;
      }
      return byKey.values.toList()..sort(compare);
    },
    decay: decay,
    decayInterval: decayInterval,
  );

  static Stream<V> passthrough<V>({
    required Stream<V> Function() source,
    void Function(AppError error)? onFailure,
    void Function()? onRecovered,
  }) {
    final controller = StreamController<V>();
    ResilientSubscription<V>? sub;

    controller
      ..onListen = () {
        sub = ResilientSubscription<V>(
          source: source,
          onData: (value) {
            if (!controller.isClosed) controller.add(value);
          },
          onFailure: (e) => onFailure?.call(e),
          onRecovered: onRecovered,
        );
      }
      ..onCancel = () async {
        await sub?.cancel();
      };

    return controller.stream;
  }

  final _Merge<T> _merge;
  final T Function(T item, DateTime now)? _decay;
  final Duration _decayInterval;

  Stream<ArrivalFeedEmission<T>> watch({
    required Stream<List<T>> Function() source,
    void Function(AppError error)? onFailure,
    void Function()? onRecovered,
  }) {
    final controller = StreamController<ArrivalFeedEmission<T>>();
    var current = <T>[];
    ResilientSubscription<List<T>>? sub;
    Timer? decayTimer;

    void emit(List<T> next, ArrivalFeedEmissionKind kind) {
      current = next;
      if (!controller.isClosed) {
        controller.add(ArrivalFeedEmission<T>(current, kind));
      }
    }

    controller
      ..onListen = () {
        sub = ResilientSubscription<List<T>>(
          source: source,
          onData: (frame) {
            final merged = _merge(current, frame);
            // A no-op merge (e.g. an empty replace frame) must not emit, so the
            // last good list stays put and downstream equality checks hold.
            if (identical(merged, current)) return;
            emit(merged, ArrivalFeedEmissionKind.source);
          },
          onFailure: (e) => onFailure?.call(e),
          onRecovered: onRecovered,
        );
        final decay = _decay;
        if (decay != null) {
          decayTimer = Timer.periodic(_decayInterval, (_) {
            if (current.isEmpty) return;
            final now = DateTime.now();
            final next = [for (final item in current) decay(item, now)];
            var changed = false;
            for (var i = 0; i < next.length; i++) {
              if (next[i] != current[i]) {
                changed = true;
                break;
              }
            }
            if (!changed) return;
            // A decay tick re-derives already-known values locally; it never
            // learned anything new from the network, so it is tagged `decay`
            // (not `source`) — consumers must not treat it as fresh (F29, F30).
            emit(next, ArrivalFeedEmissionKind.decay);
          });
        }
      }
      ..onCancel = () async {
        decayTimer?.cancel();
        await sub?.cancel();
      };

    return controller.stream;
  }
}
