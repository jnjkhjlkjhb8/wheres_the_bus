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
