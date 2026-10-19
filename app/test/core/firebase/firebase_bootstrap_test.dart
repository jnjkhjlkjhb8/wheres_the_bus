import 'dart:async';
import 'dart:isolate';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/core/firebase/firebase_bootstrap.dart';
import 'package:wheres_the_bus/core/firebase/firebase_gate.dart';
import 'package:wheres_the_bus/core/firebase/remote_config.dart';

void main() {
  setUp(FirebaseBootstrap.resetCoreInitForTesting);

  test('the default flavor leaves remote refresh offline', () async {
    final version = AppConfig.version.value;
    expect(await AppConfig.refresh(), isFalse);
    expect(AppConfig.version.value, version);
  });

  group('singleFlightCoreInit', () {
    test('concurrent callers share one in-flight initializer call', () async {
      var callCount = 0;
      final gate = Completer<void>();
      Future<void> initializer() async {
        callCount++;
        await gate.future;
      }

      final first = FirebaseBootstrap.singleFlightCoreInit(initializer);
      final second = FirebaseBootstrap.singleFlightCoreInit(initializer);

      expect(callCount, 1);
      gate.complete();
      await first;
      await second;

      expect(callCount, 1);
    });

    test(
      'a failure is not permanently cached — the next call retries',
      () async {
        var callCount = 0;
        Future<void> failingOnce() async {
          callCount++;
          if (callCount == 1) throw StateError('no network');
        }

        await expectLater(
          FirebaseBootstrap.singleFlightCoreInit(failingOnce),
          throwsA(isA<StateError>()),
        );
        await Future<void>.delayed(Duration.zero);

        await FirebaseBootstrap.singleFlightCoreInit(failingOnce);

        expect(callCount, 2);
      },
    );
  });

  group('initFailSoft', () {
    test('rethrows after logging so a caller sees the failure', () async {
      Future<void> failingInitializer({Future<void>? hiveReady}) async {
        throw StateError('firebase down');
      }

      await expectLater(
        FirebaseBootstrap.initFailSoft(initializer: failingInitializer),
        throwsA(isA<StateError>()),
      );
    });

    test('rethrows on timeout', () async {
      Future<void> hangingInitializer({Future<void>? hiveReady}) =>
          Completer<void>().future;

      await expectLater(
        FirebaseBootstrap.initFailSoft(
          initializer: hangingInitializer,
          timeout: const Duration(milliseconds: 10),
        ),
        throwsA(isA<TimeoutException>()),
      );
    });

    test('resolves normally when the initializer succeeds', () async {
      Future<void> okInitializer({Future<void>? hiveReady}) async {}

      await expectLater(
        FirebaseBootstrap.initFailSoft(initializer: okInitializer),
        completes,
      );
    });
  });
  group('token synchronization', () {
    test(
      'coalesces a pending key and distinguishes token and preference',
      () async {
        expect(await _guardScenario('coalesce'), {
          'calls': 3,
          'pendingCalls': 1,
        });
      },
    );

    test('queues preference changes behind a pending registration', () async {
      expect(await _guardScenario('queue'), {
        'before': ['start'],
        'after': ['start', 'registered', 'disabled'],
      });
    });

    test('a failed registration does not block a queued replacement', () async {
      expect(await _guardScenario('replaceFailure'), {
        'sameFailure': true,
        'replacementCalls': 1,
      });
    });

    test('a synchronous failure retries once and caches the success', () async {
      expect(await _guardScenario('retry'), {
        'sameFailure': true,
        'retries': 1,
      });
    });
  });

  test(
    'optional setup awaits each step and continues after a failed step',
    () async {
      final originalPrint = debugPrint;
      final diagnostics = <String>[];
      final calls = <String>[];
      final failure = StateError('optional service unavailable');
      final stack = StackTrace.fromString(
        '#0 optionalFailure (package:bus_test/optional.dart:1:1)',
      );
      debugPrint = (message, {wrapWidth}) {
        if (message != null) diagnostics.add(message);
      };
      try {
        await FirebaseBootstrap.runOptionalSteps([
          () async {
            calls.add('first-start');
            await Future<void>.value();
            calls.add('first-done');
          },
          () {
            calls.add('failed');
            Error.throwWithStackTrace(failure, stack);
          },
          () async => calls.add('last'),
        ]);
        expect(calls, ['first-start', 'first-done', 'failed', 'last']);
        expect(diagnostics.join('\n'), contains(failure.toString()));
        expect(diagnostics.join('\n'), contains('optionalFailure'));
      } finally {
        debugPrint = originalPrint;
      }
    },
  );

  test(
    'startup forwards Hive readiness and waits for its initializer',
    () async {
      final hive = Completer<void>();
      final release = Completer<void>();
      var calls = 0;
      var completed = false;
      final startup = FirebaseBootstrap.initFailSoft(
        initializer: ({hiveReady}) async {
          calls++;
          expect(hiveReady, same(hive.future));
          await release.future;
          completed = true;
        },
        hiveReady: hive.future,
      );
      var startupCompleted = false;
      final observed = startup.then<void>((_) {
        startupCompleted = true;
      })..ignore();
      try {
        expect(calls, 1);
        await Future<void>.delayed(Duration.zero);
        expect(startupCompleted, isFalse);
        expect(completed, isFalse);
        release.complete();
        await observed;
        expect(completed, isTrue);
        expect(startupCompleted, isTrue);
      } finally {
        if (!hive.isCompleted) hive.complete();
        if (!release.isCompleted) release.complete();
        await observed;
      }
    },
  );

  test(
    'startup preserves the original failure and its diagnostic stack',
    () async {
      final originalPrint = debugPrint;
      final diagnostics = <String>[];
      final failure = StateError('startup unavailable');
      final stack = StackTrace.fromString(
        '#0 startupFailure (package:bus_test/startup.dart:1:1)',
      );
      debugPrint = (message, {wrapWidth}) {
        if (message != null) diagnostics.add(message);
      };
      try {
        await expectLater(
          FirebaseBootstrap.initFailSoft(
            initializer: ({hiveReady}) async {
              Error.throwWithStackTrace(failure, stack);
            },
          ),
          throwsA(same(failure)),
        );
        expect(diagnostics.join('\n'), contains(failure.toString()));
        expect(diagnostics.join('\n'), contains('startupFailure'));
      } finally {
        debugPrint = originalPrint;
      }
    },
  );
  test('disabled Firebase does not initialize an empty app registry', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    expect(FirebaseGate.enabled, isFalse);
    expect(Firebase.apps, isEmpty);
    final core = _UnexpectedCoreInitialization();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final method in [
      'initializeApp',
      'initializeCore',
      'optionsFromResource',
    ]) {
      expect(
        messenger.checkMockMessageHandler(
          'dev.flutter.pigeon.firebase_core_platform_interface.'
          'FirebaseCoreHostApi.$method',
          null,
        ),
        isTrue,
      );
    }
    try {
      TestFirebaseCoreHostApi.setUp(core);
      await FirebaseBootstrap.ensureCoreInitialized();
      expect(core.coreRequests, 0);
      expect(core.appRequests, 0);
      expect(Firebase.apps, isEmpty);
    } finally {
      try {
        TestFirebaseCoreHostApi.setUp(null);
      } finally {
        FirebaseBootstrap.resetCoreInitForTesting();
      }
    }
  });
}

Future<Object?> _guardScenario(String scenario) async {
  final replies = ReceivePort();
  Isolate? worker;
  try {
    worker = await Isolate.spawn(
      _runGuardScenario,
      (replies.sendPort, scenario),
      onError: replies.sendPort,
    );
    // A broken pending-registration guard can starve its own microtask queue;
    // the parent isolate must remain able to fail and release that worker.
    return await replies.first.timeout(const Duration(seconds: 5));
  } finally {
    worker?.kill(priority: Isolate.immediate);
    replies.close();
  }
}

Future<void> _runGuardScenario((SendPort, String) request) async {
  final (replies, scenario) = request;
  final guard = FirebaseTokenSyncGuard();
  try {
    switch (scenario) {
      case 'coalesce':
        final gate = Completer<void>();
        var calls = 0;
        Future<void> sync() async {
          calls++;
          await gate.future;
        }
        final first = guard.run('device-a', 'true', sync);
        final duplicate = guard.run('device-a', 'true', sync);
        final pendingCalls = calls;
        gate.complete();
        await Future.wait([first, duplicate]);
        await guard.run('device-a', 'true', sync);
        await guard.run('device-a', 'false', sync);
        await guard.run('device-b', 'false', sync);
        Isolate.exit(replies, {'calls': calls, 'pendingCalls': pendingCalls});
      case 'queue':
        final gate = Completer<void>();
        final changes = <String>[];
        final first = guard.run('device', 'true', () async {
          changes.add('start');
          await gate.future;
          changes.add('registered');
        });
        final changed = guard.run('device', 'false', () async {
          changes.add('disabled');
        });
        final before = List<String>.of(changes);
        gate.complete();
        await Future.wait([first, changed]);
        await guard.run(
          'device',
          'false',
          () async => changes.add('duplicate'),
        );
        Isolate.exit(replies, {'before': before, 'after': changes});
      case 'replaceFailure':
        final gate = Completer<void>();
        final failure = StateError('network unavailable');
        var sameFailure = false;
        final first = guard
            .run('old', 'true', () => gate.future)
            .then<void>(
              (_) {},
              onError: (Object error, StackTrace stack) {
                sameFailure = identical(error, failure);
              },
            );
        var replacementCalls = 0;
        final changed = guard.run('new', 'true', () async {
          replacementCalls++;
        });
        gate.completeError(failure);
        await Future.wait([first, changed]);
        await guard.run('new', 'true', () async => replacementCalls++);
        Isolate.exit(replies, {
          'sameFailure': sameFailure,
          'replacementCalls': replacementCalls,
        });
      case 'retry':
        final failure = StateError('offline');
        var sameFailure = false;
        try {
          await guard.run('device', 'true', () => throw failure);
        } on Object catch (error) {
          sameFailure = identical(error, failure);
        }
        var retries = 0;
        await guard.run('device', 'true', () async => retries++);
        await guard.run('device', 'true', () async => retries++);
        Isolate.exit(replies, {'sameFailure': sameFailure, 'retries': retries});
      default:
        throw ArgumentError.value(scenario, 'scenario');
    }
  } on Object catch (error, stack) {
    Isolate.exit(replies, {'error': '$error', 'stack': '$stack'});
  }
}

class _UnexpectedCoreInitialization extends MockFirebaseApp {
  int coreRequests = 0;
  int appRequests = 0;

  @override
  Future<List<CoreInitializeResponse>> initializeCore() async {
    coreRequests++;
    return [];
  }

  @override
  Future<CoreInitializeResponse> initializeApp(
    String name,
    CoreFirebaseOptions options,
  ) async {
    appRequests++;
    throw StateError('Firebase initialization was requested while disabled');
  }
}
