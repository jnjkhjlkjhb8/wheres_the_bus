import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/app/theme/app_text_styles.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/shared/motion/app_motion.dart';
import 'package:wheres_the_bus/shared/widgets/app_badge.dart';

void main() {
  final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF3366CC));

  Future<void> mount(
    WidgetTester tester,
    Widget child, {
    bool reduced = false,
  }) => tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(colorScheme: scheme),
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduced),
        child: Scaffold(body: Center(child: child)),
      ),
    ),
  );

  Finder inBadge(Type type) =>
      find.descendant(of: find.byType(AppBadge), matching: find.byType(type));

  Container container(WidgetTester tester) =>
      tester.widget<Container>(find.byType(Container));

  BoxDecoration decoration(WidgetTester tester) =>
      container(tester).decoration! as BoxDecoration;

  group('data pill', () {
    testWidgets('is a 4-radius pill filled with the data colour', (
      tester,
    ) async {
      await mount(
        tester,
        const AppBadge(label: '307', color: Color(0xFF123456)),
      );
      expect(decoration(tester).color, const Color(0xFF123456));
      expect(
        decoration(tester).borderRadius,
        BorderRadius.circular(AppTheme.radiusChip),
      );
      expect(decoration(tester).border, isNull);
      expect(
        container(tester).padding,
        const EdgeInsets.symmetric(horizontal: AppTheme.space8, vertical: 3),
      );
      final text = tester.widget<Text>(find.text('307'));
      expect(text.style?.fontWeight, FontWeight.w600);
      expect(text.style?.fontSize, AppTextStyles.bodySmall.fontSize);
    });

    testWidgets('is static: no fade or scale even with motion on', (
      tester,
    ) async {
      await mount(tester, const AppBadge(label: '307', color: Colors.red));
      expect(inBadge(FadeTransition), findsNothing);
      expect(inBadge(ScaleTransition), findsNothing);
    });

    testWidgets('picks the text colour with the better contrast', (
      tester,
    ) async {
      for (final (gray, expected) in [
        (117, Colors.white),
        (118, Colors.black),
        (0, Colors.white),
        (255, Colors.black),
      ]) {
        await mount(
          tester,
          AppBadge(label: 'x', color: Color.fromARGB(255, gray, gray, gray)),
        );
        expect(
          tester.widget<Text>(find.text('x')).style?.color,
          expected,
          reason: 'gray $gray',
        );
      }
    });
  });

  group('status badge', () {
    testWidgets('a labelled one is a 20 high primary stadium', (tester) async {
      await mount(tester, const AppBadge(label: 'NEW'), reduced: true);
      expect(container(tester).constraints?.maxHeight, 20);
      expect(
        container(tester).padding,
        const EdgeInsets.symmetric(horizontal: AppTheme.space6),
      );
      expect(container(tester).alignment, Alignment.center);
      expect(decoration(tester).color, scheme.primary);
      expect(
        decoration(tester).borderRadius,
        BorderRadius.circular(AppTheme.radiusStadium),
      );
      expect(decoration(tester).border, isNull);
      final text = tester.widget<Text>(find.text('NEW'));
      expect(text.style?.color, scheme.onPrimary);
      expect(text.style?.fontWeight, FontWeight.w600);
      expect(tester.getSize(find.byType(Container)).height, 20);
    });

    testWidgets('an outlined one is hollow with a primary edge and text', (
      tester,
    ) async {
      await mount(tester, const AppBadge.outlined(label: 'OUT'), reduced: true);
      expect(decoration(tester).color, Colors.transparent);
      expect(decoration(tester).border, Border.all(color: scheme.primary));
      expect(
        decoration(tester).borderRadius,
        BorderRadius.circular(AppTheme.radiusStadium),
      );
      expect(
        tester.widget<Text>(find.text('OUT')).style?.color,
        scheme.primary,
      );
      expect(
        tester.widget<Text>(find.text('OUT')).style?.fontWeight,
        FontWeight.w600,
      );
    });

    testWidgets('an outlined badge ignores any data colour', (tester) async {
      await mount(tester, const AppBadge.outlined(label: 'OUT'), reduced: true);
      expect(decoration(tester).color, Colors.transparent);
    });

    testWidgets('without a label it is an 8 point error dot', (tester) async {
      await mount(tester, const AppBadge(), reduced: true);
      expect(tester.getSize(find.byType(Container)), const Size(8, 8));
      expect(decoration(tester).color, scheme.error);
      expect(decoration(tester).shape, BoxShape.circle);
      expect(find.byType(Text), findsNothing);
    });

    testWidgets('a coloured dot is still the error dot', (tester) async {
      await mount(tester, const AppBadge(color: Colors.green), reduced: true);
      expect(decoration(tester).color, scheme.error);
    });

    testWidgets('an empty label draws an empty text node', (tester) async {
      await mount(tester, const AppBadge.outlined(), reduced: true);
      expect(tester.widget<Text>(find.byType(Text)).data, '');
    });
  });

  group('entrance', () {
    testWidgets('fades and grows from 90 percent over the short duration', (
      tester,
    ) async {
      await mount(tester, const AppBadge(label: 'NEW'));
      final scale = tester.widget<ScaleTransition>(inBadge(ScaleTransition));
      final fade = tester.widget<FadeTransition>(inBadge(FadeTransition));
      expect(scale.scale.value, closeTo(0.9, 1e-9));
      expect(fade.opacity.value, 0);
      await tester.pump(AppMotion.short ~/ 2);
      final eased = AppMotion.easeOut.transform(0.5);
      expect(fade.opacity.value, closeTo(eased, 0.01));
      expect(scale.scale.value, closeTo(0.9 + 0.1 * eased, 0.01));
      await tester.pump(AppMotion.short);
      expect(fade.opacity.value, 1);
      expect(scale.scale.value, 1);
    });

    testWidgets('reduce motion shows the badge at once', (tester) async {
      await mount(tester, const AppBadge(label: 'NEW'), reduced: true);
      expect(inBadge(FadeTransition), findsNothing);
      expect(inBadge(ScaleTransition), findsNothing);
      expect(find.text('NEW'), findsOneWidget);
    });

    testWidgets('the dot animates like the label', (tester) async {
      await mount(tester, const AppBadge());
      expect(inBadge(FadeTransition), findsOneWidget);
      expect(inBadge(ScaleTransition), findsOneWidget);
    });
  });
}
