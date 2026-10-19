import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart';
import 'package:wheres_the_bus/core/errors/app_error.dart';
import 'package:wheres_the_bus/core/grpc/resilient_stream.dart';

Future<void> eventually(
  bool Function() done, {
  Duration timeout = const Duration(milliseconds: 300),
}) async {
  final end = DateTime.now().add(timeout);
  while (!done() && DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(done(), isTrue);
}

void main() {
  _resilientPublicContracts();
  test('resubscribes with backoff after error', () async {
    var subscribeCount = 0;
    final sub = ResilientSubscription<int>(
      source: () {
        subscribeCount++;
        return Stream<int>.error(const GrpcError.unavailable());
      },
      onData: (_) {},
      onFailure: (_) {},
      baseDelay: const Duration(milliseconds: 1),
      maxDelay: const Duration(milliseconds: 4),
      reportError: (_, _) {},
    );

    await eventually(() => subscribeCount >= 3);
    expect(subscribeCount, greaterThanOrEqualTo(3));
    await sub.cancel();
  });

  test('onFailure fires once at threshold', () async {
    final failures = <AppError>[];
    final sub = ResilientSubscription<int>(
      source: () => Stream<int>.error(const GrpcError.unavailable()),
      onData: (_) {},
      onFailure: failures.add,
      maxFailures: 2,
      baseDelay: const Duration(milliseconds: 1),
      maxDelay: const Duration(milliseconds: 1),
      reportError: (_, _) {},
    );

    await eventually(() => failures.isNotEmpty);
    expect(failures.length, 1);
    expect(failures.single, isA<OfflineError>());
    await sub.cancel();
  });

  test('data resets failures and calls onRecovered', () async {
    var failed = 0;
    var recovered = 0;
    var attempt = 0;
    final sub = ResilientSubscription<int>(
      source: () {
        attempt++;
        if (attempt == 1) {
          return Stream<int>.error(const GrpcError.unavailable());
        }
        return Stream<int>.value(42);
      },
      onData: (_) {},
      onFailure: (_) => failed++,
      onRecovered: () => recovered++,
      baseDelay: const Duration(milliseconds: 1),
      reportError: (_, _) {},
    );

    await eventually(() => recovered == 1);
    expect(recovered, 1);
    expect(failed, 0);
    await sub.cancel();
  });

  test('a silent reconnect recovers once the grace window passes', () async {
    final failures = <AppError>[];
    var recovered = 0;
    var attempt = 0;
    final sub = ResilientSubscription<int>(
      source: () {
        attempt++;
        // Fails until the threshold, then reconnects to a stream that never
        // emits — exactly what an alert feed does when nothing is wrong.
        if (attempt <= 2) {
          return Stream<int>.error(const GrpcError.unavailable());
        }
        return StreamController<int>().stream;
      },
      onData: (_) {},
      onFailure: failures.add,
      onRecovered: () => recovered++,
      maxFailures: 2,
      baseDelay: const Duration(milliseconds: 1),
      recoveryGrace: const Duration(milliseconds: 10),
      reportError: (_, _) {},
    );

    await eventually(() => failures.isNotEmpty);
    await eventually(() => recovered == 1);
    expect(recovered, 1, reason: 'no frame ever arrived');
    await sub.cancel();
  });

  test('a reconnect that fails again inside the grace window does not '
      'report recovery', () async {
    var recovered = 0;
    final sub = ResilientSubscription<int>(
      source: () => Stream<int>.error(const GrpcError.unavailable()),
      onData: (_) {},
      onFailure: (_) {},
      onRecovered: () => recovered++,
      maxFailures: 1,
      baseDelay: const Duration(milliseconds: 1),
      maxDelay: const Duration(milliseconds: 1),
      recoveryGrace: const Duration(milliseconds: 50),
      reportError: (_, _) {},
    );

    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(recovered, 0);
    await sub.cancel();
  });

  test('the network coming back skips the rest of the backoff', () async {
    final online = ValueNotifier<bool>(true);
    addTearDown(online.dispose);
    var subscribeCount = 0;
    final sub = ResilientSubscription<int>(
      source: () {
        subscribeCount++;
        return Stream<int>.error(const GrpcError.unavailable());
      },
      onData: (_) {},
      onFailure: (_) {},
      // Long enough that the retry could only have come from the edge.
      baseDelay: const Duration(seconds: 30),
      reportError: (_, _) {},
      online: online,
    );

    await eventually(() => subscribeCount == 1);
    online
      ..value = false
      ..value = true;

    await eventually(() => subscribeCount == 2);
    await sub.cancel();
  });

  test('a live subscription is left alone when the network flips', () async {
    final online = ValueNotifier<bool>(true);
    addTearDown(online.dispose);
    var subscribeCount = 0;
    final controllers = <StreamController<int>>[];
    final sub = ResilientSubscription<int>(
      source: () {
        subscribeCount++;
        final controller = StreamController<int>();
        controllers.add(controller);
        return controller.stream;
      },
      onData: (_) {},
      onFailure: (_) {},
      reportError: (_, _) {},
      online: online,
    );

    online
      ..value = false
      ..value = true;
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(subscribeCount, 1);
    await sub.cancel();
    for (final controller in controllers) {
      await controller.close();
    }
  });

  test('cancel stops retrying', () async {
    var subscribeCount = 0;
    final sub = ResilientSubscription<int>(
      source: () {
        subscribeCount++;
        return Stream<int>.error(const GrpcError.unavailable());
      },
      onData: (_) {},
      onFailure: (_) {},
      baseDelay: const Duration(milliseconds: 1),
      reportError: (_, _) {},
    );

    await Future<void>.delayed(Duration.zero);
    await sub.cancel();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(subscribeCount, 1);
  });

  test('clean closes back off, cap at maxDelay, and never notify', () async {
    final delays = <Duration>[];
    var failed = 0;
    final sub = ResilientSubscription<int>(
      source: Stream<int>.empty,
      onData: (_) {},
      onFailure: (_) => failed++,
      baseDelay: const Duration(milliseconds: 1),
      maxDelay: const Duration(milliseconds: 4),
      retryDelay: (delay) {
        delays.add(delay);
        return Duration.zero;
      },
      reportError: (_, _) {},
    );

    await eventually(() => delays.length >= 4);
    expect(delays.take(4), [
      const Duration(milliseconds: 1),
      const Duration(milliseconds: 2),
      const Duration(milliseconds: 4),
      const Duration(milliseconds: 4),
    ]);
    expect(failed, 0);
    await sub.cancel();
  });

  test('a synchronous throw from the source factory is handled like an '
      'async stream error: reported, retried with backoff', () async {
    var subscribeCount = 0;
    final sub = ResilientSubscription<int>(
      source: () {
        subscribeCount++;
        // No stream is ever returned — the factory itself throws, e.g. a
        // gRPC client that validates arguments before opening the channel.
        throw const GrpcError.unavailable();
      },
      onData: (_) {},
      onFailure: (_) {},
      baseDelay: const Duration(milliseconds: 1),
      maxDelay: const Duration(milliseconds: 4),
      reportError: (_, _) {},
    );

    await eventually(() => subscribeCount >= 3);
    expect(subscribeCount, greaterThanOrEqualTo(3));
    await sub.cancel();
  });

  test(
    'onFailure fires once at threshold for a synchronous factory throw, '
    'same as an async error',
    () async {
      final failures = <AppError>[];
      final sub = ResilientSubscription<int>(
        source: () => throw const GrpcError.unavailable(),
        onData: (_) {},
        onFailure: failures.add,
        maxFailures: 2,
        baseDelay: const Duration(milliseconds: 1),
        maxDelay: const Duration(milliseconds: 1),
        reportError: (_, _) {},
      );

      await eventually(() => failures.isNotEmpty);
      expect(failures.length, 1);
      expect(failures.single, isA<OfflineError>());
      await sub.cancel();
    },
  );

  test(
    'a terminal synchronous factory throw does not hot-loop retrying',
    () async {
      var subscribeCount = 0;
      final sub = ResilientSubscription<int>(
        source: () {
          subscribeCount++;
          throw const GrpcError.unauthenticated();
        },
        onData: (_) {},
        onFailure: (_) {},
        reportError: (_, _) {},
      );

      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(subscribeCount, 1);
      await sub.cancel();
    },
  );

  test('cancel stops retrying after a synchronous factory throw', () async {
    var subscribeCount = 0;
    final sub = ResilientSubscription<int>(
      source: () {
        subscribeCount++;
        throw const GrpcError.unavailable();
      },
      onData: (_) {},
      onFailure: (_) {},
      baseDelay: const Duration(milliseconds: 1),
      reportError: (_, _) {},
    );

    await Future<void>.delayed(Duration.zero);
    await sub.cancel();
    final countAfterCancel = subscribeCount;
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(subscribeCount, countAfterCancel);
  });

  test('uses the injected retry delay', () async {
    Duration? observed;
    final sub = ResilientSubscription<int>(
      source: () => Stream<int>.error(const GrpcError.unavailable()),
      onData: (_) {},
      onFailure: (_) {},
      retryDelay: (delay) {
        observed ??= delay;
        return const Duration(days: 1);
      },
      reportError: (_, _) {},
    );

    await eventually(() => observed != null);
    expect(observed, const Duration(seconds: 2));
    await sub.cancel();
  });

  test('drops the source in the background and re-listens on resume', () async {
    final foreground = ValueNotifier<bool>(true);
    addTearDown(foreground.dispose);
    var subscribeCount = 0;
    var cancelCount = 0;
    final controllers = <StreamController<int>>[];
    final sub = ResilientSubscription<int>(
      source: () {
        subscribeCount++;
        final controller = StreamController<int>(
          onCancel: () => cancelCount++,
        );
        controllers.add(controller);
        return controller.stream;
      },
      onData: (_) {},
      onFailure: (_) {},
      reportError: (_, _) {},
      foreground: foreground,
    );

    expect(subscribeCount, 1);

    foreground.value = false;
    await eventually(() => cancelCount == 1);
    expect(subscribeCount, 1, reason: 'background must not reconnect');

    foreground.value = true;
    await eventually(() => subscribeCount == 2);

    await sub.cancel();
    for (final controller in controllers) {
      await controller.close();
    }
  });

  test('a terminal error stops retrying but is re-tried once per resume '
      '(a restarting router and an expired token both produce one)', () async {
    final foreground = ValueNotifier<bool>(true);
    addTearDown(foreground.dispose);
    var subscribeCount = 0;
    final sub = ResilientSubscription<int>(
      source: () {
        subscribeCount++;
        return Stream<int>.error(const GrpcError.unauthenticated());
      },
      onData: (_) {},
      onFailure: (_) {},
      reportError: (_, _) {},
      foreground: foreground,
    );

    await eventually(() => subscribeCount == 1);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(subscribeCount, 1, reason: 'no retry loop while it stays terminal');

    foreground
      ..value = false
      ..value = true;
    await eventually(() => subscribeCount == 2);

    expect(subscribeCount, 2);
    await sub.cancel();
  });

  test('a terminal error recovers when the endpoint comes back', () async {
    final foreground = ValueNotifier<bool>(true);
    addTearDown(foreground.dispose);
    var recovered = 0;
    var attempt = 0;
    final sub = ResilientSubscription<int>(
      source: () {
        attempt++;
        if (attempt == 1) {
          return Stream<int>.error(const GrpcError.unimplemented());
        }
        return Stream<int>.value(7);
      },
      onData: (_) {},
      onFailure: (_) {},
      onRecovered: () => recovered++,
      reportError: (_, _) {},
      foreground: foreground,
    );

    await eventually(() => attempt == 1);
    foreground
      ..value = false
      ..value = true;
    await eventually(() => recovered == 1);

    expect(recovered, 1);
    await sub.cancel();
  });

  group('resilientStream', () {
    final foreground = ValueNotifier<bool>(true);
    final online = ValueNotifier<bool>(true);

    test(
      'a server-side close is reopened without surfacing anything',
      () async {
        var opened = 0;
        final values = <int>[];
        final errors = <Object>[];
        final sub = resilientStream<int>(
          () {
            opened++;
            // Each connection delivers one frame and then ends, the way a
            // rolling update's GOAWAY ends every stream on the old pod.
            return Stream<int>.value(opened);
          },
          baseDelay: const Duration(milliseconds: 1),
          maxDelay: const Duration(milliseconds: 2),
          reportError: (_, _) {},
          foreground: foreground,
          online: online,
        ).listen(values.add, onError: errors.add);

        await eventually(() => values.length >= 3);
        expect(values.take(3), [1, 2, 3]);
        expect(errors, isEmpty);
        await sub.cancel();
      },
    );

    test('a transient error is retried silently', () async {
      var opened = 0;
      final values = <int>[];
      final errors = <Object>[];
      final sub = resilientStream<int>(
        () {
          opened++;
          return opened == 1
              ? Stream<int>.error(const GrpcError.unavailable())
              : Stream<int>.value(42);
        },
        baseDelay: const Duration(milliseconds: 1),
        maxDelay: const Duration(milliseconds: 2),
        reportError: (_, _) {},
        foreground: foreground,
        online: online,
      ).listen(values.add, onError: errors.add);

      await eventually(() => values.isNotEmpty);
      expect(values.first, 42);
      expect(errors, isEmpty);
      await sub.cancel();
    });

    test('sustained failure reaches onError once', () async {
      final errors = <Object>[];
      final sub = resilientStream<int>(
        () => Stream<int>.error(const GrpcError.unavailable()),
        maxFailures: 2,
        baseDelay: const Duration(milliseconds: 1),
        maxDelay: const Duration(milliseconds: 1),
        reportError: (_, _) {},
        foreground: foreground,
        online: online,
      ).listen((_) {}, onError: errors.add);

      await eventually(() => errors.isNotEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(errors, hasLength(1));
      expect(errors.single, isA<AppError>());
      await sub.cancel();
    });
  });
}

class _OwnedBoolSignal extends ValueNotifier<bool> {
  _OwnedBoolSignal() : super(true);

  final listeners = <VoidCallback>{};

  @override
  void addListener(VoidCallback listener) {
    super.addListener(listener);
    listeners.add(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    listeners.remove(listener);
  }
}

class _OwnedFeedProbe {
  final foreground = _OwnedBoolSignal();
  final online = _OwnedBoolSignal();
  final controllers = <StreamController<int>>[];
  final failures = <AppError>[];
  final reports = <({Object error, StackTrace stack})>[];
  final delays = <Duration>[];
  final events = <String>[];
  ResilientSubscription<int>? subscription;

  void start({
    int maxFailures = 5,
    Duration maxDelay = const Duration(seconds: 1000),
    Duration recoveryGrace = const Duration(seconds: 10),
  }) {
    subscription = ResilientSubscription<int>(
      source: () {
        final controller = StreamController<int>.broadcast(sync: true);
        controllers.add(controller);
        return controller.stream;
      },
      onData: (value) => events.add('data:$value'),
      onFailure: failures.add,
      onRecovered: () => events.add('recovered'),
      reportError: (error, stack) => reports.add((error: error, stack: stack)),
      retryDelay: (delay) {
        delays.add(delay);
        return delay;
      },
      baseDelay: const Duration(seconds: 1),
      maxDelay: maxDelay,
      recoveryGrace: recoveryGrace,
      maxFailures: maxFailures,
      foreground: foreground,
      online: online,
    );
  }

  Future<void> dispose() async {
    try {
      await subscription?.cancel();
    } finally {
      try {
        await Future.wait(controllers.map((controller) => controller.close()));
      } finally {
        try {
          foreground.dispose();
        } finally {
          online.dispose();
        }
      }
    }
  }
}

Future<void> _completeOwned(
  WidgetTester tester,
  Future<void> Function() operation,
) async {
  // Create cleanup futures in the real-async zone after shared cancel futures.
  final completed = await tester.runAsync(() async {
    await operation();
    return true;
  });
  expect(completed, isTrue);
}

void _resilientPublicContracts() {
  testWidgets('initial background and offline edges do not open a feed', (
    tester,
  ) async {
    final probe = _OwnedFeedProbe();
    try {
      probe.foreground.value = false;
      probe.start();
      expect(probe.controllers, isEmpty);
      probe.online
        ..value = false
        ..value = true;
      await tester.pump(const Duration(seconds: 50));
      expect(probe.controllers, isEmpty);
      probe.foreground.value = true;
      expect(probe.controllers, hasLength(1));
      expect(probe.controllers.single.hasListener, isTrue);
      expect(probe.failures, isEmpty);
      expect(probe.events, isEmpty);
    } finally {
      await _completeOwned(tester, probe.dispose);
    }
  });

  testWidgets(
    'transient failures use capped backoff and notify at exact limit',
    (
      tester,
    ) async {
      final probe = _OwnedFeedProbe();
      try {
        probe.start(maxFailures: 8);
        for (var attempt = 0; attempt < 9; attempt++) {
          final error = StateError('transient-$attempt');
          final stack = StackTrace.fromString('source-$attempt');
          expect(probe.controllers, hasLength(attempt + 1));
          probe.controllers.last.addError(error, stack);
          expect(probe.reports, hasLength(attempt + 1));
          expect(probe.reports.last.error, same(error));
          expect(probe.reports.last.stack, same(stack));
          expect(probe.failures, hasLength(attempt < 7 ? 0 : 1));
          await tester.pump(probe.delays.last);
        }
        expect(probe.delays, [
          for (final seconds in [1, 2, 4, 8, 16, 32, 32, 32, 32])
            Duration(seconds: seconds),
        ]);
        expect(probe.failures.single, isA<UnknownError>());
        expect(probe.events, isEmpty);
      } finally {
        await _completeOwned(tester, probe.dispose);
      }
    },
  );

  testWidgets('clean closure backoff stops doubling after six closes', (
    tester,
  ) async {
    final probe = _OwnedFeedProbe();
    try {
      probe.start();
      for (var attempt = 0; attempt < 8; attempt++) {
        expect(probe.controllers, hasLength(attempt + 1));
        await _completeOwned(tester, probe.controllers.last.close);
        await tester.pump(probe.delays.last);
      }
      expect(probe.delays, [
        for (final seconds in [1, 2, 4, 8, 16, 32, 32, 32])
          Duration(seconds: seconds),
      ]);
      expect(probe.failures, isEmpty);
      expect(probe.reports, isEmpty);
      expect(probe.events, isEmpty);
    } finally {
      await _completeOwned(tester, probe.dispose);
    }
  });

  testWidgets(
    'received data resets clean-close backoff without recovery notice',
    (
      tester,
    ) async {
      final probe = _OwnedFeedProbe();
      try {
        probe.start();
        for (var attempt = 0; attempt < 2; attempt++) {
          await _completeOwned(tester, probe.controllers.last.close);
          await tester.pump(probe.delays.last);
        }
        probe.controllers.last.add(42);
        expect(probe.events, ['data:42']);
        await _completeOwned(tester, probe.controllers.last.close);
        expect(probe.delays, [
          const Duration(seconds: 1),
          const Duration(seconds: 2),
          const Duration(seconds: 1),
        ]);
        expect(probe.failures, isEmpty);
        expect(probe.reports, isEmpty);
      } finally {
        await _completeOwned(tester, probe.dispose);
      }
    },
  );

  testWidgets('one failure recovers silently at the exact grace boundary', (
    tester,
  ) async {
    final probe = _OwnedFeedProbe();
    try {
      probe.start(maxFailures: 3);
      probe.controllers.last.addError(const GrpcError.unavailable());
      await tester.pump(const Duration(seconds: 1));
      expect(probe.controllers, hasLength(2));
      await tester.pump(const Duration(seconds: 9));
      expect(probe.events, isEmpty);
      await tester.pump(const Duration(seconds: 1));
      expect(probe.events, ['recovered']);
      probe.controllers.last
        ..add(7)
        ..add(8);
      await tester.pump(const Duration(seconds: 10));
      expect(probe.events, ['recovered', 'data:7', 'data:8']);
      expect(probe.failures, isEmpty);
    } finally {
      await _completeOwned(tester, probe.dispose);
    }
  });

  testWidgets(
    'recovery precedes its first data and resets the failure threshold',
    (
      tester,
    ) async {
      final probe = _OwnedFeedProbe();
      try {
        probe.start(maxFailures: 2);
        for (var attempt = 0; attempt < 2; attempt++) {
          probe.controllers.last.addError(const GrpcError.unavailable());
          await tester.pump(probe.delays.last);
        }
        expect(probe.failures, hasLength(1));
        probe.controllers.last
          ..add(7)
          ..add(8);
        expect(probe.events, ['recovered', 'data:7', 'data:8']);
        probe.controllers.last.addError(const GrpcError.unavailable());
        expect(probe.failures, hasLength(1));
        expect(probe.delays.last, const Duration(seconds: 1));
        await tester.pump(probe.delays.last);
        probe.controllers.last.addError(const GrpcError.unavailable());
        expect(probe.failures, hasLength(2));
        expect(probe.delays.last, const Duration(seconds: 2));
      } finally {
        await _completeOwned(tester, probe.dispose);
      }
    },
  );

  testWidgets(
    'background cancels retry and resume starts a fresh failure streak',
    (
      tester,
    ) async {
      final probe = _OwnedFeedProbe();
      try {
        probe.start(maxFailures: 2);
        probe.controllers.last.addError(const GrpcError.unavailable());
        probe.foreground.value = false;
        probe.online
          ..value = false
          ..value = true;
        await tester.pump(const Duration(seconds: 100));
        expect(probe.controllers, hasLength(1));
        probe.foreground.value = true;
        expect(probe.controllers, hasLength(2));
        probe.controllers.last.addError(const GrpcError.unavailable());
        expect(probe.failures, isEmpty);
        expect(probe.delays.last, const Duration(seconds: 1));
        await _completeOwned(tester, probe.subscription!.cancel);
        expect(probe.foreground.listeners, isEmpty);
        expect(probe.online.listeners, isEmpty);
        probe.foreground
          ..value = false
          ..value = true;
        probe.online
          ..value = false
          ..value = true;
        await tester.pump(const Duration(seconds: 100));
        expect(probe.controllers, hasLength(2));
        expect(probe.events, isEmpty);
      } finally {
        await _completeOwned(tester, probe.dispose);
      }
    },
  );

  for (final error in [
    const GrpcError.unauthenticated(),
    const GrpcError.permissionDenied(),
    const GrpcError.unimplemented(),
  ]) {
    testWidgets(
      'terminal ${error.code} immediately notifies and waits for resume',
      (
        tester,
      ) async {
        final probe = _OwnedFeedProbe();
        try {
          probe.start();
          final stack = StackTrace.fromString('terminal-source');
          probe.controllers.last.addError(error, stack);
          expect(probe.reports.single.error, same(error));
          expect(probe.reports.single.stack, same(stack));
          expect(probe.failures, hasLength(1));
          expect(probe.failures.single, isA<ServerError>());
          expect((probe.failures.single as ServerError).code, error.code);
          expect(probe.delays, isEmpty);
          await tester.pump(const Duration(seconds: 100));
          expect(probe.controllers, hasLength(1));
          probe.foreground
            ..value = false
            ..value = true;
          expect(probe.controllers, hasLength(2));
          probe.controllers.last.add(9);
          expect(probe.events, ['recovered', 'data:9']);
          expect(probe.failures, hasLength(1));
        } finally {
          await _completeOwned(tester, probe.dispose);
        }
      },
    );
  }
}
