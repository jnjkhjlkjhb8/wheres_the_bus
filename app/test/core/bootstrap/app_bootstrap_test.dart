import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/core/bootstrap/app_bootstrap.dart';

void main() {
  group('AppBootstrapController', () {
    test('starts in initializing state', () {
      final controller = AppBootstrapController(
        initHive: () async {},
        initGrpc: () async {},
        initFirebase: () async {},
        initPowerSync: () async {},
      );
      expect(controller.state, AppBootstrapState.initializing);
    });

    test('reaches ready once essential init succeeds', () async {
      final controller = AppBootstrapController(
        initHive: () async {},
        initGrpc: () async {},
        initFirebase: () async {},
        initPowerSync: () async {},
      );

      await controller.start();

      expect(controller.state, AppBootstrapState.ready);
    });

    test('fails closed when Hive init throws', () async {
      final controller = AppBootstrapController(
        initHive: () async => throw StateError('disk full'),
        initGrpc: () async {},
        initFirebase: () async {},
        initPowerSync: () async {},
      );

      await controller.start();

      expect(controller.state, AppBootstrapState.failed);
      expect(controller.lastError, isA<StateError>());
      expect(controller.lastErrorPhase, AppBootstrapFailurePhase.storage);
    });

    test('fails closed when gRPC config validation throws', () async {
      final controller = AppBootstrapController(
        initHive: () async {},
        initGrpc: () async => throw StateError('bad config'),
        initFirebase: () async {},
        initPowerSync: () async {},
      );

      await controller.start();

      expect(controller.state, AppBootstrapState.failed);
      expect(controller.lastErrorPhase, AppBootstrapFailurePhase.network);
    });

    test(
      'degrades (not fails) when PowerSync init throws after ready',
      () async {
        final controller = AppBootstrapController(
          initHive: () async {},
          initGrpc: () async {},
          initFirebase: () async {},
          initPowerSync: () async => throw StateError('offline'),
        );

        await controller.start();
        // Let the fire-and-forget PowerSync/Firebase branches settle.
        await Future<void>.delayed(Duration.zero);

        expect(controller.state, AppBootstrapState.degraded);
      },
    );

    test('degrades when Firebase init throws after ready', () async {
      final controller = AppBootstrapController(
        initHive: () async {},
        initGrpc: () async {},
        initFirebase: () async => throw StateError('no network'),
        initPowerSync: () async {},
      );

      await controller.start();
      await Future<void>.delayed(Duration.zero);

      expect(controller.state, AppBootstrapState.degraded);
    });

    test('notifies listeners on every state transition', () async {
      final controller = AppBootstrapController(
        initHive: () async {},
        initGrpc: () async {},
        initFirebase: () async {},
        initPowerSync: () async {},
      );
      final seen = <AppBootstrapState>[];
      controller.addListener(() => seen.add(controller.state));

      await controller.start();

      expect(seen, contains(AppBootstrapState.ready));
    });

    test('retry re-runs essential init and can recover to ready', () async {
      var hiveAttempts = 0;
      final controller = AppBootstrapController(
        initHive: () async {
          hiveAttempts++;
          if (hiveAttempts == 1) throw StateError('transient');
        },
        initGrpc: () async {},
        initFirebase: () async {},
        initPowerSync: () async {},
      );

      await controller.start();
      expect(controller.state, AppBootstrapState.failed);

      await controller.retry();

      expect(controller.state, AppBootstrapState.ready);
      expect(hiveAttempts, 2);
      expect(controller.lastError, isNull);
      expect(controller.lastErrorPhase, isNull);
    });

    test(
      'retry publishes initializing while essential storage is pending',
      () async {
        final storageReady = Completer<void>();
        var attempts = 0;
        final controller = AppBootstrapController(
          initHive: () async {
            if (++attempts == 1) throw StateError('storage unavailable');
            await storageReady.future;
          },
          initGrpc: () async {},
          initFirebase: () async {},
          initPowerSync: () async {},
        );
        Future<void>? recovery;
        addTearDown(() async {
          try {
            if (!storageReady.isCompleted) storageReady.complete();
            await recovery;
          } finally {
            controller.dispose();
          }
        });
        final states = <AppBootstrapState>[];
        controller.addListener(() => states.add(controller.state));

        await controller.start();
        expect(controller.state, AppBootstrapState.failed);
        recovery = controller.retry();

        expect(controller.state, AppBootstrapState.initializing);
        expect(states, [
          AppBootstrapState.failed,
          AppBootstrapState.initializing,
        ]);
        storageReady.complete();
        await recovery;
        expect(controller.state, AppBootstrapState.ready);
        expect(states, [
          AppBootstrapState.failed,
          AppBootstrapState.initializing,
          AppBootstrapState.ready,
        ]);
        expect(controller.lastError, isNull);
        expect(controller.lastErrorPhase, isNull);
      },
    );

    for (final service in ['firebase', 'powersync']) {
      test(
        '$service failure emits a diagnostic and degrades after ready',
        () async {
          final serviceReady = Completer<void>();
          final failure = StateError('$service unavailable');
          final messages = <String>[];
          final originalDebugPrint = debugPrint;
          final controller = AppBootstrapController(
            initHive: () async {},
            initGrpc: () async {},
            initFirebase: service == 'firebase'
                ? () => serviceReady.future
                : () async {},
            initPowerSync: service == 'powersync'
                ? () => serviceReady.future
                : () async {},
          );
          addTearDown(() async {
            try {
              if (!serviceReady.isCompleted) serviceReady.complete();
              await Future<void>.delayed(Duration.zero);
            } finally {
              controller.dispose();
              debugPrint = originalDebugPrint;
            }
          });
          debugPrint = (message, {wrapWidth}) {
            if (message != null) messages.add(message);
          };

          await controller.start();
          expect(controller.state, AppBootstrapState.ready);
          serviceReady.completeError(failure);
          await Future<void>.delayed(Duration.zero);

          expect(controller.state, AppBootstrapState.degraded);
          expect(controller.lastError, isNull);
          expect(controller.lastErrorPhase, isNull);
          expect(
            messages.where(
              (message) =>
                  message.contains('[bootstrap]') &&
                  message.contains(service) &&
                  message.contains(failure.toString()),
            ),
            hasLength(1),
          );
        },
      );
    }
  });
}
