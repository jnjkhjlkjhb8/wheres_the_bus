import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/app/theme/app_text_styles.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/shared/motion/app_motion.dart';
import 'package:wheres_the_bus/shared/widgets/app_dialog.dart';

import '../../support/helpers/i18n.dart';

Future<void> _show(
  WidgetTester tester, {
  String title = 'Title',
  String? content,
  Widget? body,
  List<Widget>? actions,
  bool settle = true,
}) async {
  await tester.pumpWidget(
    i18nApp(
      Builder(
        builder: (context) => TextButton(
          onPressed: () => AppDialog.show<void>(
            context,
            title: title,
            content: content,
            body: body,
            actions: actions,
          ),
          child: const Text('open'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pump();
  if (settle) await tester.pumpAndSettle();
}

Column _column(WidgetTester tester) => tester.widget<Column>(
  find.descendant(
    of: find.byType(AppDialog),
    matching: find.byType(Column),
  ),
);

void main() {
  group('layout', () {
    testWidgets('a title-only dialog is a lone heading in an elevated shell', (
      tester,
    ) async {
      await _show(tester);
      final dialog = tester.widget<Dialog>(find.byType(Dialog));
      final scheme = Theme.of(tester.element(find.byType(Dialog))).colorScheme;
      expect(dialog.backgroundColor, scheme.surfaceContainerHigh);
      expect(
        dialog.shape,
        RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusModal),
        ),
      );
      final column = _column(tester);
      expect(column.mainAxisSize, MainAxisSize.min);
      expect(column.crossAxisAlignment, CrossAxisAlignment.start);
      expect(column.children, hasLength(1));
      final title = tester.widget<Text>(find.text('Title'));
      expect(title.style?.fontSize, AppTextStyles.heading2.fontSize);
      expect(title.style?.fontWeight, FontWeight.w600);
      final padding = tester.widget<Padding>(
        find
            .ancestor(of: find.byType(Column), matching: find.byType(Padding))
            .first,
      );
      expect(padding.padding, const EdgeInsets.all(AppTheme.space24));
    });

    testWidgets('content sits 8 below the title in the secondary tone', (
      tester,
    ) async {
      await _show(tester, content: 'Details');
      final scheme = Theme.of(tester.element(find.byType(Dialog))).colorScheme;
      final children = _column(tester).children;
      expect(children, hasLength(3));
      expect((children[1] as SizedBox).height, AppTheme.space8);
      final text = tester.widget<Text>(find.text('Details'));
      expect(text.style?.color, scheme.onSurfaceVariant);
      expect(text.style?.fontSize, AppTextStyles.bodyRegular.fontSize);
    });

    testWidgets('a body sits 16 below, and after the content', (tester) async {
      await _show(
        tester,
        content: 'Details',
        body: const SizedBox(key: Key('body'), height: 10),
      );
      final children = _column(tester).children;
      expect(children, hasLength(5));
      expect((children[3] as SizedBox).height, AppTheme.space16);
      expect(children[4].key, const Key('body'));
    });

    testWidgets('actions sit 24 below, right aligned, 8 apart', (
      tester,
    ) async {
      await _show(
        tester,
        actions: const [
          SizedBox(key: Key('a'), width: 40, height: 20),
          SizedBox(key: Key('b'), width: 40, height: 20),
        ],
      );
      final children = _column(tester).children;
      expect(children, hasLength(3));
      expect((children[1] as SizedBox).height, AppTheme.space24);
      final row = children[2] as Row;
      expect(row.mainAxisAlignment, MainAxisAlignment.end);
      expect(row.children, hasLength(2));
      for (final wrapped in row.children) {
        expect(
          (wrapped as Padding).padding,
          const EdgeInsets.only(left: AppTheme.space8),
        );
      }
      final a = tester.getTopRight(find.byKey(const Key('a')));
      final b = tester.getTopLeft(find.byKey(const Key('b')));
      expect(b.dx - a.dx, AppTheme.space8);
    });

    testWidgets('an empty action list still reserves nothing visible', (
      tester,
    ) async {
      await _show(tester, actions: const []);
      expect(_column(tester).children, hasLength(3));
    });
  });

  group('modal behaviour', () {
    testWidgets('tapping the scrim dismisses the dialog', (tester) async {
      await _show(tester);
      expect(find.text('Title'), findsOneWidget);
      await tester.tapAt(const Offset(2, 2));
      await tester.pumpAndSettle();
      expect(find.text('Title'), findsNothing);
    });

    testWidgets('the scrim is 54 percent black and labelled by the title', (
      tester,
    ) async {
      await _show(tester, title: 'Delete?');
      final barrier = tester.widget<ModalBarrier>(
        find.byType(ModalBarrier).last,
      );
      expect(barrier.color, Colors.black54);
      expect(barrier.semanticsLabel, 'Delete?');
      expect(barrier.dismissible, isTrue);
    });

    testWidgets('a modal that opts out of dismissal ignores the scrim', (
      tester,
    ) async {
      await tester.pumpWidget(
        i18nApp(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => showAppModal<void>(
                context: context,
                barrierDismissible: false,
                builder: (_) => const Text('locked'),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      final barrier = tester.widget<ModalBarrier>(
        find.byType(ModalBarrier).last,
      );
      expect(barrier.dismissible, isFalse);
      expect(barrier.semanticsLabel, '');
      await tester.tapAt(const Offset(2, 2));
      await tester.pumpAndSettle();
      expect(find.text('locked'), findsOneWidget);
    });

    testWidgets('the transition runs for the sheet duration', (tester) async {
      await _show(tester, settle: false);
      await tester.pump(AppMotion.sheet - const Duration(milliseconds: 20));
      final mid = tester.widget<ScaleTransition>(
        find.ancestor(
          of: find.byType(AppDialog),
          matching: find.byType(ScaleTransition),
        ),
      );
      expect(mid.scale.value, lessThan(1));
      await tester.pump(const Duration(milliseconds: 40));
      final done = tester.widget<ScaleTransition>(
        find.ancestor(
          of: find.byType(AppDialog),
          matching: find.byType(ScaleTransition),
        ),
      );
      expect(done.scale.value, 1);
    });

    testWidgets('it fades in with the same curve it scales with', (
      tester,
    ) async {
      await _show(tester, settle: false);
      await tester.pump(const Duration(milliseconds: 70));
      final fade = tester.widget<FadeTransition>(
        find.ancestor(
          of: find.byType(AppDialog),
          matching: find.byType(FadeTransition),
        ),
      );
      final scale = tester.widget<ScaleTransition>(
        find.ancestor(
          of: find.byType(AppDialog),
          matching: find.byType(ScaleTransition),
        ),
      );
      final t = 70 / AppMotion.sheet.inMilliseconds;
      final eased = AppMotion.easeOut.transform(t);
      expect(fade.opacity.value, closeTo(eased, 0.02));
      expect(scale.scale.value, closeTo(0.92 + 0.08 * eased, 0.02));
    });

    testWidgets('closing eases out on the flipped curve', (tester) async {
      await _show(tester);
      await tester.tapAt(const Offset(2, 2));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 70));
      final fade = tester.widget<FadeTransition>(
        find.ancestor(
          of: find.byType(AppDialog),
          matching: find.byType(FadeTransition),
        ),
      );
      final t = 1 - 70 / AppMotion.sheet.inMilliseconds;
      final eased = AppMotion.easeOut.flipped.transform(t);
      expect(fade.opacity.value, closeTo(eased, 0.02));
      await tester.pumpAndSettle();
    });
  });
}
