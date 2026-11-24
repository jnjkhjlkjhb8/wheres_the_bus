import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/shared/widgets/native_controls.dart';
import 'package:wheres_the_bus/shared/widgets/ui_kit_host.dart';

import '../../support/helpers/fake_uikit.dart';

Widget _app(Widget child, {Brightness brightness = Brightness.light}) =>
    MaterialApp(
      theme: ThemeData(brightness: brightness),
      home: Scaffold(body: Center(child: child)),
    );

void main() {
  test('UIKit draws controls on iOS only', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final ios = usesUiKitControls;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final android = usesUiKitControls;
    debugDefaultTargetPlatformOverride = null;

    expect((ios, android), (true, false));
  });

  testWidgets('UiKitBarScope is seen below it and nowhere else', (
    tester,
  ) async {
    late bool inside;
    late bool outside;
    await tester.pumpWidget(
      Column(
        children: [
          Builder(
            builder: (context) {
              outside = UiKitBarScope.of(context);
              return const SizedBox();
            },
          ),
          UiKitBarScope(
            child: Builder(
              builder: (context) {
                inside = UiKitBarScope.of(context);
                return const SizedBox();
              },
            ),
          ),
        ],
      ),
    );

    expect((inside, outside), (true, false));
  });

  group('on iOS', () {
    testWidgetsOnIos('time wheel opens on the time and reports each change', (
      tester,
    ) async {
      final uiKit = FakeUiKit(NativeTimeWheel.viewType);
      final picked = <TimeOfDay>[];
      await tester.pumpWidget(
        _app(
          SizedBox(
            height: 216,
            child: NativeTimeWheel(
              initial: const TimeOfDay(hour: 8, minute: 5),
              onChanged: picked.add,
            ),
          ),
          brightness: Brightness.dark,
        ),
      );
      await tester.pumpAndSettle();
      await uiKit.send(tester, 'other', arguments: {'hour': 1, 'minute': 1});
      await uiKit.send(tester, 'changed', arguments: 'not a time');
      await uiKit.send(
        tester,
        'changed',
        arguments: {'hour': 12, 'minute': 35},
      );

      expect(
        NativeTimeWheel.viewType,
        'me.rabbitsayhello.wheresthebus/native_time_wheel',
      );
      expect(uiKit.creationParams(), {'hour': 8, 'minute': 5, 'dark': true});
      expect(picked, [const TimeOfDay(hour: 12, minute: 35)]);
      // In a draggable sheet, so it takes its own swipes.
      final host = tester.widget<UiKitHost>(find.byType(UiKitHost));
      expect(host.claimGestures, isTrue);
      expect(
        tester
            .widget<UiKitView>(find.byType(UiKitView))
            .gestureRecognizers!
            .single
            .constructor(),
        isA<EagerGestureRecognizer>(),
      );
    });

    testWidgetsOnIos('icon button sends its symbol and reports taps', (
      tester,
    ) async {
      final uiKit = FakeUiKit(NativeIconButton.viewType);
      var taps = 0;
      await tester.pumpWidget(
        _app(
          NativeIconButton(
            symbol: 'bookmark',
            label: '收藏',
            onTap: () => taps++,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final ink = Theme.of(
        tester.element(find.byType(NativeIconButton)),
      ).colorScheme.onSurface;
      await uiKit.send(tester, 'other');
      await uiKit.send(tester, 'tap');

      expect(
        NativeIconButton.viewType,
        'me.rabbitsayhello.wheresthebus/native_icon_button',
      );
      expect(uiKit.creationParams(), {
        'symbol': 'bookmark',
        'label': '收藏',
        'prominent': false,
        'tint': ink.toARGB32(),
        'dark': false,
      });
      expect(taps, 1);
      expect(
        tester.getSize(find.byType(NativeIconButton)),
        const Size.square(NativeIconButton.dimension),
      );
      expect(NativeIconButton.dimension, 44);
    });

    testWidgetsOnIos('a prominent button keeps the system tint', (
      tester,
    ) async {
      final uiKit = FakeUiKit(NativeIconButton.viewType);
      await tester.pumpWidget(
        _app(
          NativeIconButton(
            symbol: 'bell.badge.fill',
            label: '提醒',
            prominent: true,
            onTap: () {},
          ),
          brightness: Brightness.dark,
        ),
      );
      await tester.pumpAndSettle();

      final params = uiKit.creationParams();
      expect(params['prominent'], isTrue);
      expect(params['tint'], isNull);
      expect(params['dark'], isTrue);
    });
  });
}
