import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/shared/widgets/ui_kit_host.dart';

import '../../support/helpers/fake_uikit.dart';

const _type = 'test/host';

Widget _host(
  Map<String, Object?> params, {
  void Function(String, Object?)? onEvent,
  bool claimGestures = false,
}) => Directionality(
  textDirection: TextDirection.ltr,
  child: UiKitHost(
    viewType: _type,
    params: params,
    onEvent: onEvent,
    claimGestures: claimGestures,
  ),
);

void main() {
  testWidgetsOnIos(
    'creates with params and re-sends them once the channel exists',
    (
      tester,
    ) async {
      final uiKit = FakeUiKit(_type);
      await tester.pumpWidget(_host({'a': 1}));
      await tester.pumpAndSettle();

      expect(uiKit.created.single['viewType'], _type);
      expect(uiKit.creationParams(), {'a': 1});
      expect(uiKit.updates, [
        {'a': 1},
      ]);
    },
  );

  testWidgetsOnIos('pushes a change to the same view, skips an equal rebuild', (
    tester,
  ) async {
    final uiKit = FakeUiKit(_type);
    await tester.pumpWidget(_host({'a': 1}));
    await tester.pumpAndSettle();
    await tester.pumpWidget(_host({'a': 1}));
    await tester.pumpWidget(_host({'a': 2}));
    await tester.pumpAndSettle();

    expect(uiKit.created, hasLength(1));
    expect(uiKit.updates, [
      {'a': 1},
      {'a': 2},
    ]);
  });

  testWidgetsOnIos('forwards events, and stops listening once disposed', (
    tester,
  ) async {
    final uiKit = FakeUiKit(_type);
    final events = <(String, Object?)>[];
    await tester.pumpWidget(
      _host(const {}, onEvent: (m, a) => events.add((m, a))),
    );
    await tester.pumpAndSettle();

    expect(await uiKit.send(tester, 'tap', arguments: 3), isTrue);
    await tester.pumpWidget(const SizedBox());
    expect(await uiKit.send(tester, 'tap'), isFalse);
    expect(events, [('tap', 3)]);
  });

  testWidgetsOnIos('an event with no listener is ignored', (tester) async {
    final uiKit = FakeUiKit(_type);
    await tester.pumpWidget(_host(const {}));
    await tester.pumpAndSettle();

    expect(await uiKit.send(tester, 'tap'), isTrue);
  });

  testWidgetsOnIos('claims gestures only when asked', (tester) async {
    FakeUiKit(_type);
    await tester.pumpWidget(_host(const {}));
    expect(
      tester.widget<UiKitView>(find.byType(UiKitView)).gestureRecognizers,
      isNull,
    );

    await tester.pumpWidget(_host(const {}, claimGestures: true));
    final claimed = tester
        .widget<UiKitView>(find.byType(UiKitView))
        .gestureRecognizers!;
    expect(claimed.single.constructor(), isA<EagerGestureRecognizer>());
  });
}
