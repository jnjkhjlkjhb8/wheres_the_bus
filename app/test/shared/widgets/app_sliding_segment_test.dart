import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/motion/app_motion.dart';
import 'package:wheres_the_bus/shared/widgets/app_sliding_segment.dart';

void main() {
  testWidgets('thumb stays centred on the selected label', (tester) async {
    const days = {0: '一', 1: '二', 2: '三', 3: '四', 4: '五', 5: '六', 6: '日'};

    for (final selected in days.keys) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 402,
                child: AppSlidingSegment<int>(
                  options: days,
                  value: selected,
                  onChanged: (_) {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final thumb = tester.getRect(
        find.descendant(
          of: find.byType(Positioned),
          matching: find.byType(Container),
        ),
      );
      final label = tester.getRect(find.text(days[selected]!));
      expect(
        thumb.center.dx,
        moreOrLessEquals(label.center.dx, epsilon: 0.5),
        reason: 'thumb drifted off option $selected',
      );
    }
  });

  group('drag', () {
    const options = {0: '去程', 1: '返程'};

    // The control is 200 wide, centred in the 800x600 test view, so the track
    // runs 300..500 with 4px of padding: two 96px pills starting at x=304.
    Future<int?> pumpAndDrag(
      WidgetTester tester, {
      required double from,
      required double by,
    }) async {
      int? changed;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 200,
                child: AppSlidingSegment<int>(
                  options: options,
                  value: 0,
                  onChanged: (v) => changed = v,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final gesture = await tester.startGesture(Offset(from, 300));
      // Several steps rather than one jump, so the drag reads as tracking a
      // finger rather than a teleport.
      for (var i = 0; i < 4; i++) {
        await gesture.moveBy(Offset(by / 4, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await gesture.up();
      await tester.pumpAndSettle();
      return changed;
    }

    testWidgets('dragging the thumb moves the selection', (tester) async {
      expect(await pumpAndDrag(tester, from: 350, by: 96), 1);
    });

    testWidgets('dragging off the thumb changes nothing', (tester) async {
      // Starts on the second pill, which is not the thumb: only the thumb is
      // draggable, so this is a cancelled tap and not a selection.
      expect(await pumpAndDrag(tester, from: 450, by: -96), isNull);
    });

    testWidgets('a flick past the end stays inside the range', (tester) async {
      expect(await pumpAndDrag(tester, from: 350, by: 400), 1);
    });
  });

  group('thumb mechanics', () {
    // 200 wide, centred in the 800x600 view: the 192px inner track starts at
    // x=304, so three pills are 64 wide at 304, 368 and 432.
    const three = {0: 'a', 1: 'b', 2: 'c'};
    const stride = 64.0;
    const trackLeft = 304.0;

    Future<List<int>> pumpSegment(
      WidgetTester tester, {
      int value = 0,
      Map<int, String> options = three,
      bool reduced = false,
      Set<int> muted = const {},
      AppSegmentStyle style = AppSegmentStyle.groove,
      ThemeData? theme,
    }) async {
      final changes = <int>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          locale: const Locale('zh'),
          localizationsDelegates: AppI18n.localizationsDelegates,
          supportedLocales: AppI18n.supportedLocales,
          home: Scaffold(
            body: MediaQuery(
              data: MediaQueryData(disableAnimations: reduced),
              child: Center(
                child: SizedBox(
                  width: 200,
                  child: AppSlidingSegment<int>(
                    options: options,
                    value: value,
                    muted: muted,
                    style: style,
                    onChanged: changes.add,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return changes;
    }

    Rect thumb(WidgetTester tester) => tester.getRect(
      find.descendant(
        of: find.byType(Positioned),
        matching: find.byType(Container),
      ),
    );

    testWidgets('pulling past the first segment meets rubber-band '
        'resistance', (tester) async {
      await pumpSegment(tester);
      final gesture = await tester.startGesture(const Offset(330, 300));
      await gesture.moveBy(const Offset(-30, 0));
      await tester.pump();
      await gesture.moveBy(const Offset(-stride, 0));
      await tester.pump();

      // raw -1 stride past the end resists to -(1 * .12 / 1.12) strides.
      const resisted = -(1 * 0.12 / 1.12);
      expect(thumb(tester).left, closeTo(trackLeft + resisted * stride, 0.01));
      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('pulling past the last segment resists the same way', (
      tester,
    ) async {
      await pumpSegment(tester, value: 2);
      final gesture = await tester.startGesture(const Offset(460, 300));
      await gesture.moveBy(const Offset(30, 0));
      await tester.pump();
      await gesture.moveBy(const Offset(stride, 0));
      await tester.pump();

      const resisted = 2 + 1 * 0.12 / 1.12;
      expect(thumb(tester).left, closeTo(trackLeft + resisted * stride, 0.01));
      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('a slow, short drag settles on the nearest segment', (
      tester,
    ) async {
      final changes = await pumpSegment(tester);
      final gesture = await tester.startGesture(const Offset(330, 300));
      await gesture.moveBy(const Offset(10, 0));
      await tester.pump(const Duration(milliseconds: 300));
      await gesture.moveBy(const Offset(10, 0));
      await tester.pump(const Duration(milliseconds: 300));
      await gesture.up();
      await tester.pumpAndSettle();

      expect(changes, isEmpty);
      expect(thumb(tester).left, closeTo(trackLeft, 0.5));
    });

    testWidgets('a moderate flick lands where it was heading', (tester) async {
      final changes = await pumpSegment(tester);
      final pointer = TestPointer();
      var t = const Duration(seconds: 1);
      var x = 330.0;
      await tester.sendEventToBinding(
        pointer.down(Offset(x, 300), timeStamp: t),
      );
      // About 280px/s: 4.4 segments/s, a projection of ~0.9 of a segment.
      for (var k = 0; k < 8; k++) {
        t += const Duration(milliseconds: 16);
        x += 4.5;
        await tester.sendEventToBinding(
          pointer.move(Offset(x, 300), timeStamp: t),
        );
      }
      await tester.sendEventToBinding(pointer.up(timeStamp: t));
      await tester.pumpAndSettle();

      expect(changes, [1]);
      expect(thumb(tester).left, closeTo(trackLeft + stride, 0.5));
    });

    testWidgets('a backwards flick moves backwards', (tester) async {
      final changes = await pumpSegment(tester, value: 2);
      final pointer = TestPointer();
      var t = const Duration(seconds: 1);
      var x = 460.0;
      await tester.sendEventToBinding(
        pointer.down(Offset(x, 300), timeStamp: t),
      );
      for (var k = 0; k < 8; k++) {
        t += const Duration(milliseconds: 16);
        x -= 4.5;
        await tester.sendEventToBinding(
          pointer.move(Offset(x, 300), timeStamp: t),
        );
      }
      await tester.sendEventToBinding(pointer.up(timeStamp: t));
      await tester.pumpAndSettle();

      expect(changes, [1]);
    });

    testWidgets('pressing the thumb shrinks it and release restores it', (
      tester,
    ) async {
      await pumpSegment(tester);
      final rest = thumb(tester).width;
      final gesture = await tester.startGesture(const Offset(330, 300));
      await tester.pump();
      await tester.pump(AppMotion.press * 2);

      expect(
        thumb(tester).width,
        closeTo(rest * AppMotion.pressedScale, 0.01),
      );
      await gesture.up();
      await tester.pumpAndSettle();
      expect(thumb(tester).width, closeTo(rest, 0.01));
    });

    for (final (name, x) in [
      ('left edge', trackLeft),
      ('right edge', trackLeft + stride),
    ]) {
      testWidgets('a touch on the thumb $name grabs it', (tester) async {
        await pumpSegment(tester);
        final rest = thumb(tester).width;
        final gesture = await tester.startGesture(Offset(x, 300));
        await tester.pump();
        await tester.pump(AppMotion.press * 2);

        expect(thumb(tester).width, lessThan(rest));
        await gesture.up();
        await tester.pumpAndSettle();
      });
    }

    testWidgets('a touch beside the thumb does not grab it', (tester) async {
      await pumpSegment(tester);
      final rest = thumb(tester).width;
      final gesture = await tester.startGesture(
        const Offset(trackLeft + stride + 5, 300),
      );
      await tester.pump();
      await tester.pump(AppMotion.press * 2);

      expect(thumb(tester).width, rest);
      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('reduced motion presses and moves without animating', (
      tester,
    ) async {
      await pumpSegment(tester, reduced: true);
      final rest = thumb(tester).width;
      final gesture = await tester.startGesture(const Offset(330, 300));
      await tester.pump(const Duration(milliseconds: 1));
      expect(
        thumb(tester).width,
        closeTo(rest * AppMotion.pressedScale, 0.01),
      );
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 1));

      await tester.tap(find.text('c'));
      await tester.pump();
      expect(thumb(tester).left, closeTo(trackLeft + 2 * stride, 0.01));
    });

    testWidgets('a tap moves the thumb even before the parent follows', (
      tester,
    ) async {
      final changes = await pumpSegment(tester);

      await tester.tap(find.text('c'));
      await tester.pumpAndSettle();

      expect(changes, [2]);
      expect(thumb(tester).left, closeTo(trackLeft + 2 * stride, 0.5));
    });

    testWidgets('a value change from outside carries the thumb along', (
      tester,
    ) async {
      await pumpSegment(tester);
      await pumpSegment(tester, value: 1);

      expect(thumb(tester).left, closeTo(trackLeft + stride, 0.5));
    });

    testWidgets('the selected option is the only one marked selected', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpSegment(tester, value: 1);

      bool selected(String label) => tester
          .widget<Semantics>(
            find.ancestor(
              of: find.text(label),
              matching: find.byWidgetPredicate(
                (w) => w is Semantics && w.properties.selected != null,
              ),
            ),
          )
          .properties
          .selected!;
      expect(selected('a'), isFalse);
      expect(selected('b'), isTrue);
      expect(selected('c'), isFalse);
      handle.dispose();
    });

    testWidgets('labels light up under the thumb and muted ones dim', (
      tester,
    ) async {
      await pumpSegment(tester, value: 1, muted: {2});
      final cs = Theme.of(
        tester.element(find.byType(AppSlidingSegment<int>)),
      ).colorScheme;

      TextStyle style(String l) => tester.widget<Text>(find.text(l)).style!;
      expect(style('b').fontWeight, FontWeight.w600);
      expect(style('b').color, cs.onSurface);
      expect(style('a').fontWeight, FontWeight.w400);
      expect(style('a').color, cs.onSurfaceVariant);
      expect(style('c').color, cs.onSurfaceVariant.withValues(alpha: .4));
    });

    for (final dark in [false, true]) {
      testWidgets('the groove skin (dark=$dark)', (tester) async {
        final theme = dark ? AppTheme.dark : AppTheme.light;
        await pumpSegment(tester, theme: theme);
        final cs = theme.colorScheme;

        final track = tester.widget<Container>(
          find.byWidgetPredicate(
            (w) => w is Container && w.padding == const EdgeInsets.all(4),
          ),
        );
        final trackDecoration = track.decoration! as BoxDecoration;
        expect(
          trackDecoration.color,
          Colors.black.withValues(alpha: dark ? 0.30 : 0.05),
        );
        expect(trackDecoration.borderRadius, BorderRadius.circular(10));

        final thumbBox = tester.widget<Container>(
          find.descendant(
            of: find.byType(Positioned),
            matching: find.byType(Container),
          ),
        );
        final d = thumbBox.decoration! as BoxDecoration;
        expect(
          d.color,
          dark ? cs.surfaceContainerHighest : cs.surfaceContainerLow,
        );
        expect(d.borderRadius, BorderRadius.circular(7));
        expect(d.border == null, dark);
        final shadow = d.boxShadow!.single;
        expect(
          shadow.color,
          Colors.black.withValues(alpha: dark ? .25 : .05),
        );
        expect(shadow.blurRadius, dark ? 2 : 4);
        expect(shadow.offset, Offset(0, dark ? 1 : 2));
        if (!dark) {
          expect(
            (d.border! as Border).top.color,
            Colors.black.withValues(alpha: .04),
          );
        }
      });
    }

    testWidgets('the floating skin inverts against a dark thumb', (
      tester,
    ) async {
      await pumpSegment(tester, style: AppSegmentStyle.floating);
      final cs = AppTheme.light.colorScheme;
      final scheme = Theme.of(
        tester.element(find.byType(AppSlidingSegment<int>)),
      ).colorScheme;

      final thumbBox = tester.widget<Container>(
        find.descendant(
          of: find.byType(Positioned),
          matching: find.byType(Container),
        ),
      );
      expect((thumbBox.decoration! as BoxDecoration).color, scheme.onSurface);
      expect(
        tester.widget<Text>(find.text('a')).style!.color,
        scheme.surface,
      );
      expect(cs, isNotNull);
    });

    testWidgets('a static segment shows its glyph only when given one', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: AppStaticSegment(label: '單向', leading: Icons.repeat),
          ),
        ),
      );
      expect(find.byIcon(Icons.repeat), findsOneWidget);

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: AppStaticSegment(label: '單向')),
        ),
      );
      expect(find.byType(Icon), findsNothing);
    });
  });
}
