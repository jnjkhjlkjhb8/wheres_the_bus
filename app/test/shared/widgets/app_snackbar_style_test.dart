import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/app/theme/app_shadows.dart';
import 'package:wheres_the_bus/app/theme/app_text_styles.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/shared/motion/app_motion.dart';
import 'package:wheres_the_bus/shared/motion/pressable.dart';
import 'package:wheres_the_bus/shared/widgets/app_snackbar.dart';

Future<void> _show(
  WidgetTester tester,
  void Function(BuildContext) onTap, {
  ThemeData? theme,
  bool reduced = false,
  double width = 800,
}) async {
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: theme ?? AppTheme.light,
      home: MediaQuery(
        data: MediaQueryData(
          size: Size(width, 800),
          disableAnimations: reduced,
        ),
        child: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => onTap(context),
              child: const Text('go'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('go'));
  await tester.pump();
}

SnackBar _snackBar(WidgetTester tester) =>
    tester.widget<SnackBar>(find.byType(SnackBar));

Finder get _pill => find
    .ancestor(
      of: find.byType(IntrinsicHeight),
      matching: find.byType(Container),
    )
    .first;

void main() {
  group('the shell', () {
    testWidgets('floats transparent and flat so only the pill is drawn', (
      tester,
    ) async {
      await _show(tester, (c) => AppSnackbar.show(c, 'hi'));
      final bar = _snackBar(tester);
      expect(bar.behavior, SnackBarBehavior.floating);
      expect(bar.backgroundColor, Colors.transparent);
      expect(bar.elevation, 0);
      expect(bar.padding, EdgeInsets.zero);
      expect(bar.dismissDirection, DismissDirection.down);
    });

    testWidgets('lingers 2 seconds, or 4 when it carries an action', (
      tester,
    ) async {
      await _show(tester, (c) => AppSnackbar.show(c, 'hi'));
      expect(_snackBar(tester).duration, const Duration(seconds: 2));
      await _show(
        tester,
        (c) => AppSnackbar.show(c, 'hi', action: 'undo'),
      );
      expect(_snackBar(tester).duration, const Duration(seconds: 4));
    });

    testWidgets('an explicit duration wins over both defaults', (tester) async {
      await _show(
        tester,
        (c) => AppSnackbar.show(
          c,
          'hi',
          action: 'undo',
          duration: const Duration(seconds: 9),
        ),
      );
      expect(_snackBar(tester).duration, const Duration(seconds: 9));
    });

    testWidgets('enters slowly and leaves quickly', (tester) async {
      await _show(tester, (c) => AppSnackbar.show(c, 'hi'));
      final controller = _snackBar(tester).animation as AnimationController;
      expect(controller.duration, AppMotion.medium);
      expect(controller.reverseDuration, AppMotion.short);
    });

    testWidgets('a new toast replaces the one on screen', (tester) async {
      await _show(tester, (c) => AppSnackbar.show(c, 'one'));
      AppSnackbar.show(tester.element(find.text('go')), 'two');
      await tester.pumpAndSettle();
      expect(find.text('one'), findsNothing);
      expect(find.text('two'), findsOneWidget);
    });
  });

  group('the pill', () {
    testWidgets('is ink in light mode with a card radius and floating shadow', (
      tester,
    ) async {
      await _show(tester, (c) => AppSnackbar.show(c, 'hi'));
      final decoration =
          tester.widget<Container>(_pill).decoration! as BoxDecoration;
      expect(decoration.color, AppTheme.inkLight);
      expect(
        decoration.borderRadius,
        BorderRadius.circular(AppTheme.radiusCard),
      );
      expect(decoration.boxShadow, AppShadows.floating);
    });

    testWidgets('is the lifted surface in dark mode', (tester) async {
      await _show(
        tester,
        (c) => AppSnackbar.show(c, 'hi'),
        theme: AppTheme.dark,
      );
      final decoration =
          tester.widget<Container>(_pill).decoration! as BoxDecoration;
      expect(decoration.color, AppTheme.surfaceHighlightDark);
    });

    testWidgets('is at least 44 tall, at most 440 wide and padded by 16', (
      tester,
    ) async {
      await _show(tester, (c) => AppSnackbar.show(c, 'hi'));
      final pill = tester.widget<Container>(_pill);
      expect(
        pill.constraints,
        const BoxConstraints(maxWidth: 440, minHeight: 44),
      );
      expect(
        pill.padding,
        const EdgeInsets.symmetric(horizontal: AppTheme.space16),
      );
      expect(tester.getSize(_pill).height, 44);
    });

    testWidgets('a long message wraps inside the 440 cap and grows taller', (
      tester,
    ) async {
      await _show(tester, (c) => AppSnackbar.show(c, 'long ' * 60));
      final size = tester.getSize(_pill);
      expect(size.width, 440);
      expect(size.height, greaterThan(44));
    });

    testWidgets('the message is white-on-ink at 500 weight, 1.4 line height', (
      tester,
    ) async {
      await _show(tester, (c) => AppSnackbar.show(c, 'hello'));
      final text = tester.widget<Text>(find.text('hello'));
      expect(text.style?.color, AppTheme.inkDark);
      expect(text.style?.fontWeight, FontWeight.w500);
      expect(text.style?.height, 1.4);
      expect(text.style?.fontSize, AppTextStyles.bodySmall.fontSize);
      final padding = tester.widget<Padding>(
        find
            .ancestor(of: find.text('hello'), matching: find.byType(Padding))
            .first,
      );
      expect(
        padding.padding,
        const EdgeInsets.symmetric(vertical: AppTheme.space12),
      );
    });

    testWidgets('the row hugs its content and stretches its children', (
      tester,
    ) async {
      await _show(tester, (c) => AppSnackbar.show(c, 'hello'));
      final row = tester.widget<Row>(
        find
            .descendant(
              of: find.byType(IntrinsicHeight),
              matching: find.byType(Row),
            )
            .first,
      );
      expect(row.mainAxisSize, MainAxisSize.min);
      expect(row.crossAxisAlignment, CrossAxisAlignment.stretch);
      final center = tester.widget<Center>(
        find
            .ancestor(of: find.text('hello'), matching: find.byType(Center))
            .first,
      );
      expect(center.widthFactor, 1);
      expect(center.heightFactor, isNull);
    });
  });

  group('the leading icon', () {
    testWidgets('neutral has none', (tester) async {
      await _show(tester, (c) => AppSnackbar.show(c, 'hi'));
      expect(find.byType(Icon), findsNothing);
    });

    testWidgets('success is a green check 20 wide with a 12 gap', (
      tester,
    ) async {
      await _show(
        tester,
        (c) => AppSnackbar.show(c, 'ok', type: SnackType.success),
      );
      final icon = tester.widget<Icon>(find.byType(Icon));
      expect(icon.icon, Icons.check_circle_outline_rounded);
      expect(icon.size, 20);
      expect(icon.color, AppTheme.statusArriving);
      final iconRect = tester.getRect(find.byType(Icon));
      final textRect = tester.getRect(find.text('ok'));
      expect(textRect.left - iconRect.right, AppTheme.space12);
    });

    testWidgets('error is a lighter red than the token so it reads on ink', (
      tester,
    ) async {
      await _show(
        tester,
        (c) => AppSnackbar.show(c, 'bad', type: SnackType.error),
      );
      final icon = tester.widget<Icon>(find.byType(Icon));
      expect(icon.icon, Icons.error_outline_rounded);
      expect(icon.size, 20);
      expect(icon.color, const Color(0xFFF97066));
    });
  });

  group('the action', () {
    testWidgets('is bold white, 12 after the message, 44 wide at least', (
      tester,
    ) async {
      await _show(
        tester,
        (c) => AppSnackbar.show(c, 'msg', action: 'x', onAction: () {}),
      );
      final label = tester.widget<Text>(find.text('x'));
      expect(label.style?.color, Colors.white);
      expect(label.style?.fontWeight, FontWeight.w700);
      final box = tester.getRect(
        find
            .ancestor(of: find.text('x'), matching: find.byType(ConstrainedBox))
            .first,
      );
      expect(box.width, greaterThanOrEqualTo(44));
      expect(
        box.left - tester.getRect(find.text('msg')).right,
        AppTheme.space12,
      );
      expect(box.height, 44);
    });

    testWidgets('speaks its label to assistive technology', (tester) async {
      await _show(
        tester,
        (c) => AppSnackbar.show(c, 'msg', action: 'undo', onAction: () {}),
      );
      final semantics = tester.widget<Semantics>(
        find
            .descendant(
              of: find.byType(Pressable),
              matching: find.byType(Semantics),
            )
            .first,
      );
      expect(semantics.properties.label, 'undo');
      expect(semantics.properties.button, isTrue);
    });

    testWidgets('a tap without a callback still closes the toast', (
      tester,
    ) async {
      await _show(tester, (c) => AppSnackbar.show(c, 'msg', action: 'undo'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('undo'));
      await tester.pumpAndSettle();
      expect(find.text('msg'), findsNothing);
    });

    testWidgets('no action label means no action', (tester) async {
      await _show(tester, (c) => AppSnackbar.show(c, 'msg'));
      expect(
        find.byType(ConstrainedBox).evaluate().where((e) {
          final w = e.widget as ConstrainedBox;
          return w.constraints == const BoxConstraints(minWidth: 44);
        }),
        isEmpty,
      );
    });
  });

  group('the entrance', () {
    testWidgets('rises half its height late in the animation', (tester) async {
      await _show(tester, (c) => AppSnackbar.show(c, 'hi'));
      final slide = tester.widget<SlideTransition>(
        find.ancestor(of: _pill, matching: find.byType(SlideTransition)).first,
      );
      expect(slide.position.value, const Offset(0, 0.5));
      await tester.pumpAndSettle();
      expect(slide.position.value, Offset.zero);
    });

    testWidgets('holds still for the first 40 percent of the animation', (
      tester,
    ) async {
      await _show(tester, (c) => AppSnackbar.show(c, 'hi'));
      final slide = tester.widget<SlideTransition>(
        find.ancestor(of: _pill, matching: find.byType(SlideTransition)).first,
      );
      await tester.pump(AppMotion.medium * 0.2);
      expect(slide.position.value, const Offset(0, 0.5));
      await tester.pump(AppMotion.medium * 0.4);
      expect(slide.position.value.dy, lessThan(0.5));
      expect(slide.position.value.dy, greaterThan(0));
    });

    testWidgets('reduce motion drops the slide', (tester) async {
      await _show(tester, (c) => AppSnackbar.show(c, 'hi'), reduced: true);
      final nearest = tester.widget<SlideTransition>(
        find.ancestor(of: _pill, matching: find.byType(SlideTransition)).first,
      );
      expect(nearest.position.value, Offset.zero);
      expect(find.text('hi'), findsOneWidget);
    });
  });
}
