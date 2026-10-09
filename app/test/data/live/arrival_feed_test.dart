import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart';
import 'package:wheres_the_bus/core/errors/app_error.dart';
import 'package:wheres_the_bus/data/live/arrival_feed.dart';

/// A minimal arrival with an estimate that decays toward zero, standing in for
/// the real domain models so the feed's orchestration is tested in isolation.
@immutable
class _Arrival {
  const _Arrival(this.key, this.estimate);
  final String key;
  final int estimate;

  _Arrival decayed(int by) =>
      _Arrival(key, estimate - by > 0 ? estimate - by : 0);

  @override
  bool operator ==(Object other) =>
      other is _Arrival && other.key == key && other.estimate == estimate;

  @override
  int get hashCode => Object.hash(key, estimate);
}

Future<void> _pump() => Future<void>.delayed(Duration.zero);

void main() {
  group('replace policy', () {
    test('each frame replaces the whole list', () async {
      final source = StreamController<List<_Arrival>>();
      final feed = ArrivalFeed<_Arrival>.replace();
      final emitted = <List<_Arrival>>[];
      final sub = feed
          .watch(source: () => source.stream)
          .listen((e) => emitted.add(e.arrivals));
      addTearDown(sub.cancel);

      source
        ..add([const _Arrival('a', 300), const _Arrival('b', 120)])
        ..add([const _Arrival('c', 60)]);
      await _pump();

      expect(emitted, [
        [const _Arrival('a', 300), const _Arrival('b', 120)],
        [const _Arrival('c', 60)],
      ]);
    });

    test('empty frame is ignored while entries already exist', () async {
      final source = StreamController<List<_Arrival>>();
      final feed = ArrivalFeed<_Arrival>.replace();
      final emitted = <List<_Arrival>>[];
      final sub = feed
          .watch(source: () => source.stream)
          .listen((e) => emitted.add(e.arrivals));
      addTearDown(sub.cancel);

      source
        ..add([const _Arrival('a', 300)])
        ..add(const []); // empty frame -> no emission, last good list stays
      await _pump();

      expect(emitted, [
        [const _Arrival('a', 300)],
      ]);
    });

    test('every frame emission carries the source kind', () async {
      final source = StreamController<List<_Arrival>>();
      final feed = ArrivalFeed<_Arrival>.replace();
      final kinds = <ArrivalFeedEmissionKind>[];
      final sub = feed
          .watch(source: () => source.stream)
          .listen((e) => kinds.add(e.kind));
      addTearDown(sub.cancel);

      source.add([const _Arrival('a', 300)]);
      await _pump();

      expect(kinds, [ArrivalFeedEmissionKind.source]);
    });

    test('decay tick re-derives the current list between frames', () async {
      final source = StreamController<List<_Arrival>>();
      final feed = ArrivalFeed<_Arrival>.replace(
        decay: (a, _) => a.decayed(60),
        decayInterval: const Duration(milliseconds: 20),
      );
      final emitted = <List<_Arrival>>[];
      final sub = feed
          .watch(source: () => source.stream)
          .listen((e) => emitted.add(e.arrivals));
      addTearDown(sub.cancel);

      source.add([const _Arrival('a', 300)]);
      await _pump();
      await Future<void>.delayed(const Duration(milliseconds: 30));

      // Server frame first, then at least one decayed re-emission.
      expect(emitted.first, [const _Arrival('a', 300)]);
      expect(emitted.length, greaterThanOrEqualTo(2));
      expect(emitted.last.single.estimate, lessThan(300));
    });

    test(
      'a decay re-emission is tagged decay, not source — the local '
      'countdown must not be mistaken for a fresh network frame (F29)',
      () async {
        final source = StreamController<List<_Arrival>>();
        final feed = ArrivalFeed<_Arrival>.replace(
          decay: (a, _) => a.decayed(60),
          decayInterval: const Duration(milliseconds: 20),
        );
        final kinds = <ArrivalFeedEmissionKind>[];
        final sub = feed
            .watch(source: () => source.stream)
            .listen((e) => kinds.add(e.kind));
        addTearDown(sub.cancel);

        source.add([const _Arrival('a', 300)]);
        await _pump();
        await Future<void>.delayed(const Duration(milliseconds: 30));

        expect(kinds.first, ArrivalFeedEmissionKind.source);
        expect(kinds.skip(1), everyElement(ArrivalFeedEmissionKind.decay));
      },
    );

    test('decay tick that changes no value is suppressed', () async {
      final source = StreamController<List<_Arrival>>();
      final feed = ArrivalFeed<_Arrival>.replace(
        decay: (a, _) => a.decayed(60),
        decayInterval: const Duration(milliseconds: 20),
      );
      final emitted = <List<_Arrival>>[];
      final sub = feed
          .watch(source: () => source.stream)
          .listen((e) => emitted.add(e.arrivals));
      addTearDown(sub.cancel);

      // Already at zero: every decay tick re-derives the same value, so only
      // the initial server frame emits — no tick re-emits an equal list.
      source.add([const _Arrival('a', 0)]);
      await _pump();
      await Future<void>.delayed(const Duration(milliseconds: 70));

      expect(emitted, [
        [const _Arrival('a', 0)],
      ]);
    });
  });

  group('replace policy with compare', () {
    test('each frame is sorted by the compare policy', () async {
      final source = StreamController<List<_Arrival>>();
      final feed = ArrivalFeed<_Arrival>.replace(
        compare: (a, b) => a.estimate.compareTo(b.estimate),
      );
      final emitted = <List<_Arrival>>[];
      final sub = feed
          .watch(source: () => source.stream)
          .listen((e) => emitted.add(e.arrivals));
      addTearDown(sub.cancel);

      source.add([const _Arrival('a', 300), const _Arrival('b', 120)]);
      await _pump();

      expect(emitted.last, [
        const _Arrival('b', 120),
        const _Arrival('a', 300),
      ]);
    });
  });

  group('passthrough (identity) policy', () {
    test('forwards each lone value verbatim', () async {
      final source = StreamController<int>();
      final got = <int>[];
      final sub = ArrivalFeed.passthrough(
        source: () => source.stream,
      ).listen(got.add);
      addTearDown(sub.cancel);

      source
        ..add(1)
        ..add(2);
      await _pump();

      expect(got, [1, 2]);
    });

    test('cancel stops delivery', () async {
      final source = StreamController<int>.broadcast();
      final got = <int>[];
      final sub = ArrivalFeed.passthrough(
        source: () => source.stream,
      ).listen(got.add);

      source.add(1);
      await _pump();
      await sub.cancel();
      source.add(2);
      await _pump();

      expect(got, [1]);
    });

    test('onFailure surfaces after a terminal error', () async {
      final failures = <AppError>[];
      final sub = ArrivalFeed.passthrough<int>(
        source: () => Stream<int>.error(const GrpcError.unauthenticated()),
        onFailure: failures.add,
      ).listen((_) {});
      addTearDown(sub.cancel);

      final end = DateTime.now().add(const Duration(seconds: 2));
      while (failures.isEmpty && DateTime.now().isBefore(end)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      expect(failures.single, isA<AppError>());
    });

    test('onRecovered fires after a non-terminal error then a value', () async {
      var attempt = 0;
      var recovered = 0;
      final got = <int>[];
      final sub = ArrivalFeed.passthrough<int>(
        source: () {
          attempt++;
          if (attempt == 1) {
            return Stream<int>.error(const GrpcError.unavailable());
          }
          return Stream<int>.value(7);
        },
        onRecovered: () => recovered++,
      ).listen(got.add);
      addTearDown(sub.cancel);

      final end = DateTime.now().add(const Duration(seconds: 5));
      while (recovered == 0 && DateTime.now().isBefore(end)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      expect(recovered, 1);
      expect(got.last, 7);
    });
  });

  group('upsertByKey policy', () {
    test('frames upsert by key and sort by compare', () async {
      final source = StreamController<List<_Arrival>>();
      final feed = ArrivalFeed<_Arrival>.upsertByKey(
        key: (a) => a.key,
        compare: (a, b) => a.estimate.compareTo(b.estimate),
      );
      final emitted = <List<_Arrival>>[];
      final sub = feed
          .watch(source: () => source.stream)
          .listen((e) => emitted.add(e.arrivals));
      addTearDown(sub.cancel);

      source
        ..add([const _Arrival('a', 300)])
        ..add([const _Arrival('b', 120)]) // insert, sorts ahead of a
        ..add([const _Arrival('a', 60)]); // update a, now sorts first
      await _pump();

      expect(emitted.last, [
        const _Arrival('a', 60),
        const _Arrival('b', 120),
      ]);
    });
  });

  test('source error then value recovers via ResilientSubscription', () async {
    var attempt = 0;
    final feed = ArrivalFeed<_Arrival>.replace();
    var recovered = 0;
    final emitted = <List<_Arrival>>[];
    final sub = feed
        .watch(
          source: () {
            attempt++;
            if (attempt == 1) {
              return Stream<List<_Arrival>>.error(
                const GrpcError.unavailable(),
              );
            }
            return Stream<List<_Arrival>>.value([const _Arrival('a', 60)]);
          },
          onRecovered: () => recovered++,
        )
        .listen((e) => emitted.add(e.arrivals));
    addTearDown(sub.cancel);

    // The wrapper's base retry delay is ~2s; allow a generous window.
    final end = DateTime.now().add(const Duration(seconds: 5));
    while (recovered == 0 && DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    expect(recovered, 1);
    expect(emitted.last, [const _Arrival('a', 60)]);
  });

  test('onFailure surfaces after the wrapper gives up', () async {
    final failures = <AppError>[];
    final feed = ArrivalFeed<_Arrival>.replace();
    final sub = feed
        .watch(
          // A terminal gRPC error trips the failure callback immediately.
          source: () =>
              Stream<List<_Arrival>>.error(const GrpcError.unauthenticated()),
          onFailure: failures.add,
        )
        .listen((_) {});
    addTearDown(sub.cancel);

    final end = DateTime.now().add(const Duration(seconds: 2));
    while (failures.isEmpty && DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    expect(failures.single, isA<AppError>());
  });

  test('cancel stops the source and the decay timer', () async {
    final source = StreamController<List<_Arrival>>();
    final feed = ArrivalFeed<_Arrival>.replace(
      decay: (a, _) => a.decayed(60),
      decayInterval: const Duration(milliseconds: 10),
    );
    final emitted = <List<_Arrival>>[];
    final sub = feed
        .watch(source: () => source.stream)
        .listen((e) => emitted.add(e.arrivals));

    source.add([const _Arrival('a', 300)]);
    await _pump();
    await sub.cancel();
    final countAfterCancel = emitted.length;

    // No further server frames or decay ticks reach a cancelled subscription.
    source.add([const _Arrival('b', 120)]);
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(emitted.length, countAfterCancel);
  });
}
