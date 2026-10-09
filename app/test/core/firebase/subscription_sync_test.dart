import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/core/firebase/subscription_sync.dart';

void main() {
  late StreamController<void> changes;
  late Set<String> scope;
  late List<Set<String>> sent;
  late List<Completer<void>> pending;
  late bool fail;

  SubscriptionSync build() => SubscriptionSync(
    changes: () => changes.stream,
    currentScope: () => scope,
    replace: (next) {
      sent.add(next);
      if (fail) return Future<void>.error(StateError('offline'));
      final completer = Completer<void>();
      pending.add(completer);
      return completer.future;
    },
  );

  void settleAll() {
    for (final completer in pending) {
      if (!completer.isCompleted) completer.complete();
    }
    pending.clear();
  }

  setUp(() {
    changes = StreamController<void>.broadcast();
    scope = {'bus:R1'};
    sent = [];
    pending = [];
    fail = false;
  });

  tearDown(() => changes.close());

  test('start pushes the current scope once', () async {
    final sync = build();
    addTearDown(sync.stop);

    sync.start();
    await pumpEventQueue();
    settleAll();
    await pumpEventQueue();

    expect(sent, [
      {'bus:R1'},
    ]);
  });

  test('a 收藏 change pushes the new scope', () async {
    final sync = build();
    addTearDown(sync.stop);
    sync.start();
    await pumpEventQueue();
    settleAll();
    await pumpEventQueue();

    scope = {'bus:R1', 'mrt:BL'};
    changes.add(null);
    await pumpEventQueue();
    settleAll();
    await pumpEventQueue();

    expect(sent.last, {'bus:R1', 'mrt:BL'});
  });

  test('an unchanged scope is not resent', () async {
    final sync = build();
    addTearDown(sync.stop);
    sync.start();
    await pumpEventQueue();
    settleAll();
    await pumpEventQueue();

    // A 收藏 edit that does not change what is subscribed (renaming a title,
    // reordering the list) must not produce traffic.
    changes.add(null);
    await pumpEventQueue();
    settleAll();
    await pumpEventQueue();

    expect(sent, hasLength(1));
  });

  // Two replaces in flight at once could land out of order and leave the
  // server holding the older set for good.
  test('changes during a send are folded into one follow-up send', () async {
    final sync = build();
    addTearDown(sync.stop);
    sync.start();
    await pumpEventQueue();
    expect(sent, hasLength(1), reason: 'first send is still in flight');

    scope = {'bus:R2'};
    changes.add(null);
    await pumpEventQueue();
    scope = {'bus:R3'};
    changes.add(null);
    await pumpEventQueue();
    expect(
      sent,
      hasLength(1),
      reason: 'nothing may overlap the in-flight send',
    );

    settleAll();
    await pumpEventQueue();
    settleAll();
    await pumpEventQueue();

    // One follow-up, carrying the latest scope rather than each intermediate.
    expect(sent, hasLength(2));
    expect(sent.last, {'bus:R3'});
  });

  test('a failed send is retried on the next change', () async {
    fail = true;
    final sync = build();
    addTearDown(sync.stop);
    sync.start();
    await pumpEventQueue();
    expect(sent, hasLength(1));

    // Same scope as the failed attempt: it must still be resent, because the
    // server never actually received it.
    fail = false;
    changes.add(null);
    await pumpEventQueue();
    settleAll();
    await pumpEventQueue();

    expect(sent, hasLength(2));
    expect(sent.last, {'bus:R1'});
  });
}
