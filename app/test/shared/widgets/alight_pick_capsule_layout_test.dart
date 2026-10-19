import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/app/theme/app_shadows.dart';
import 'package:wheres_the_bus/app/theme/app_text_styles.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/shared/motion/app_motion.dart';
import 'package:wheres_the_bus/shared/motion/pressable.dart';
import 'package:wheres_the_bus/shared/widgets/alight_track/alight_pick_capsule.dart';

import '../../support/helpers/haptic_log.dart';
import '../../support/helpers/i18n.dart';

void main() {
  group('capsule', () {
    Future<void> mount(WidgetTester tester, {VoidCallback? onCancel}) =>
        tester.pumpWidget(
          i18nApp(
            Scaffold(
              body: Center(
                child: AlightPickCapsule(onCancel: onCancel ?? () {}),
              ),
            ),
          ),
        );

    testWidgets('is a 44 tall ink stadium with the floating shadow', (
      tester,
    ) async {
      await mount(tester);
      final scheme = Theme.of(tester.element(find.byType(AlightPickCapsule))).colorScheme;
      final container = tester.widget<Container>(
        find.descendant(
          of: find.byType(AlightPickCapsule),
          matching: find.byType(Container),
        ),
      );
      expect(tester.getSize(find.byType(Container).first).height, 44);
      expect(
        container.padding,
        const EdgeInsets.only(left: AppTheme.space16, right: AppTheme.space4),
      );
      final decoration = container.decoration! as BoxDecoration;
      expect(decoration.color, scheme.onSurface);
      expect(
        decoration.borderRadius,
        BorderRadius.circular(AppTheme.radiusStadium),
      );
      expect(decoration.boxShadow, AppShadows.floating);
    });

    testWidgets('states the task in a semibold surface-coloured title', (
      tester,
    ) async {
      await mount(tester);
      final scheme = Theme.of(tester.element(find.byType(AlightPickCapsule))).colorScheme;
      final title = tester.widget<Text>(find.text(zhStrings.alightPickTitle));
      expect(title.style?.fontWeight, FontWeight.w600);
      expect(title.style?.color, scheme.surface);
      expect(title.style?.fontSize, AppTextStyles.bodyRegular.fontSize);
      final row = tester.widget<Row>(
        find.descendant(of: find.byType(AlightPickCapsule), matching: find.byType(Row)),
      );
      expect(row.mainAxisSize, MainAxisSize.min);
    });

    testWidgets('the way out is a 40 point target with an 18 point glyph', (
      tester,
    ) async {
      await mount(tester);
      final icon = tester.widget<Icon>(find.byIcon(Icons.close_rounded));
      expect(icon.size, 18);
      final target = tester.getSize(
        find.ancestor(of: find.byIcon(Icons.close_rounded), matching: find.byType(SizedBox)).first,
      );
      expect(target, const Size(40, 40));
      final gap = tester.getRect(find.byType(Pressable)).left -
          tester.getRect(find.text(zhStrings.alightPickTitle)).right;
      expect(gap, AppTheme.space4);
      expect(
        tester.widget<Pressable>(find.byType(Pressable)).semanticLabel,
        zhStrings.commonClose,
      );
    });

    testWidgets('closing taps lightly and leaves pick mode once', (
      tester,
    ) async {
      final haptics = captureHaptics();
      var cancels = 0;
      await mount(tester, onCancel: () => cancels++);
      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pump();
      expect(cancels, 1);
      expect(haptics, ['HapticFeedbackType.lightImpact']);
    });
  });

  group('host', () {
    Future<void> mount(
      WidgetTester tester, {
      required bool picking,
      bool reduced = false,
      VoidCallback? onCancel,
    }) => tester.pumpWidget(
      i18nApp(
        MediaQuery(
          data: MediaQueryData(disableAnimations: reduced),
          child: Scaffold(
            body: AlightPickCapsuleHost(
              picking: picking,
              onCancel: onCancel ?? () {},
              child: const SizedBox.expand(key: Key('content')),
            ),
          ),
        ),
      ),
    );

    testWidgets('pins the capsule across the top and centres it', (
      tester,
    ) async {
      await mount(tester, picking: true);
      final positioned = tester.widget<Positioned>(
        find.descendant(
          of: find.byType(AlightPickCapsuleHost),
          matching: find.byType(Positioned),
        ),
      );
      expect((positioned.left, positioned.right), (0, 0));
      final capsule = tester.getCenter(find.byType(AlightPickCapsule));
      expect(capsule.dx, 400);
      expect(find.byKey(const Key('content')), findsOneWidget);
    });

    testWidgets('picking shows the capsule and takes taps', (tester) async {
      var cancels = 0;
      await mount(tester, picking: true, onCancel: () => cancels++);
      expect(
        tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
        1,
      );
      final ignore = tester.widget<IgnorePointer>(
        find.ancestor(of: find.byType(AnimatedOpacity), matching: find.byType(IgnorePointer)).first,
      );
      expect(ignore.ignoring, isFalse);
      await tester.tap(find.byIcon(Icons.close_rounded));
      expect(cancels, 1);
    });

    testWidgets('not picking hides the capsule and ignores taps', (
      tester,
    ) async {
      var cancels = 0;
      await mount(tester, picking: false, onCancel: () => cancels++);
      expect(
        tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
        0,
      );
      final ignore = tester.widget<IgnorePointer>(
        find.ancestor(of: find.byType(AnimatedOpacity), matching: find.byType(IgnorePointer)).first,
      );
      expect(ignore.ignoring, isTrue);
      await tester.tap(find.byIcon(Icons.close_rounded), warnIfMissed: false);
      expect(cancels, 0);
    });

    testWidgets('fades over the short duration, instantly when reduced', (
      tester,
    ) async {
      await mount(tester, picking: true);
      var fade = tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity));
      expect(fade.duration, AppMotion.short);
      expect(fade.curve, AppMotion.easeOut);
      await mount(tester, picking: true, reduced: true);
      fade = tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity));
      expect(fade.duration, AppMotion.instant);
    });
  });
}
