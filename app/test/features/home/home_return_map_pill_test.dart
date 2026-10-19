import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/app/theme/app_shadows.dart';
import 'package:wheres_the_bus/app/theme/app_text_styles.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/data/models/near_models.dart';
import 'package:wheres_the_bus/features/home/home_screen.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/motion/app_motion.dart';
import 'package:wheres_the_bus/shared/motion/pressable.dart';

Widget _app(Widget child, {ThemeData? theme, bool reduced = false}) =>
    MaterialApp(
      theme: theme ?? AppTheme.light,
      locale: const Locale('zh'),
      localizationsDelegates: AppI18n.localizationsDelegates,
      supportedLocales: AppI18n.supportedLocales,
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduced),
        child: Scaffold(body: Center(child: child)),
      ),
    );

void main() {
  group('return-to-map pill', () {
    final i18n = lookupAppI18n(const Locale('zh'));
    const appearCurve = Interval(0, 0.4, curve: AppMotion.easeOut);
    const morphCurve = Interval(0.3, 1, curve: AppMotion.easeOut);
    const contentCurve = Interval(0.65, 1, curve: AppMotion.easeOut);

    double pillWidth() {
      final label = TextPainter(
        text: TextSpan(
          text: i18n.homeBackToMap,
          style: AppTextStyles.bodySmall.copyWith(fontWeight: FontWeight.w600),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      addTearDown(label.dispose);
      return 12 * 2 + 20 + 6 + label.width;
    }

    Future<void> revealUpTo(
      WidgetTester tester,
      double fraction, {
      ThemeData? theme,
    }) async {
      await tester.pumpWidget(
        _app(returnMapPillForTest(visible: false, onTap: () {}), theme: theme),
      );
      await tester.pumpWidget(
        _app(returnMapPillForTest(visible: true, onTap: () {}), theme: theme),
      );
      await tester.pump();
      await tester.pump(AppMotion.sheet * fraction);
    }

    Finder pillFade() => find.ancestor(
      of: find.byType(Pressable),
      matching: find.byType(Opacity),
    );

    Finder box() => find.descendant(
      of: find.byType(Pressable),
      matching: find.byType(Container),
    );

    testWidgets('nothing is drawn while hidden', (tester) async {
      await tester.pumpWidget(
        _app(returnMapPillForTest(visible: false, onTap: () {})),
      );

      expect(find.byType(Pressable), findsNothing);
    });

    testWidgets('it starts as a dot while the pill itself fades in', (
      tester,
    ) async {
      await revealUpTo(tester, 0.2);

      expect(tester.getSize(box().first), const Size(12, 12));
      final fade = tester.widget<Opacity>(pillFade().first);
      expect(fade.opacity, appearCurve.transform(0.2));
      final scale = tester.widget<Transform>(
        find
            .descendant(of: pillFade().first, matching: find.byType(Transform))
            .first,
      );
      expect(
        scale.transform.storage[0],
        closeTo(0.85 + 0.15 * appearCurve.transform(0.2), 1e-9),
      );
    });

    for (final fraction in [0.5, 0.8, 1.0]) {
      testWidgets('at $fraction of the reveal it has morphed that far', (
        tester,
      ) async {
        await revealUpTo(tester, fraction);
        final morph = morphCurve.transform(fraction);
        final width = 12 + (pillWidth() - 12) * morph;
        final height = 12 + (44 - 12) * morph;

        expect(tester.getSize(box().first), Size(width, height));
        final decoration =
            tester.widget<Container>(box().first).decoration! as BoxDecoration;
        expect(decoration.borderRadius, BorderRadius.circular(height / 2));
        final content = tester.widget<Opacity>(
          find.descendant(
            of: find.byType(Pressable),
            matching: find.byType(Opacity),
          ),
        );
        expect(content.opacity, contentCurve.transform(fraction));
      });
    }

    testWidgets('its slot is the full pill wide and 44 high', (tester) async {
      await revealUpTo(tester, 0.2);

      final slot = tester.getSize(
        find
            .ancestor(
              of: find.byType(Pressable),
              matching: find.byType(SizedBox),
            )
            .first,
      );
      expect(slot, Size(pillWidth(), 44));
    });

    testWidgets('the label is laid out at full pill width and clipped', (
      tester,
    ) async {
      await revealUpTo(tester, 0.5);

      final overflow = tester.widget<OverflowBox>(find.byType(OverflowBox));
      expect(overflow.minWidth, pillWidth());
      expect(overflow.maxWidth, pillWidth());
      expect(
        tester.widget<Container>(box().first).clipBehavior,
        Clip.antiAlias,
      );
    });

    testWidgets('light floats on a shadow, dark carries none', (tester) async {
      await revealUpTo(tester, 1);
      var decoration =
          tester.widget<Container>(box().first).decoration! as BoxDecoration;
      expect(decoration.boxShadow, AppShadows.floating);

      await revealUpTo(tester, 1, theme: AppTheme.dark);
      decoration =
          tester.widget<Container>(box().first).decoration! as BoxDecoration;
      expect(decoration.boxShadow, isEmpty);
    });

    testWidgets('with reduce motion it is the whole pill at once', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(returnMapPillForTest(visible: true, onTap: () {}), reduced: true),
      );

      expect(tester.getSize(box().first), Size(pillWidth(), 44));
      expect(
        tester
            .widget<Opacity>(
              find
                  .ancestor(
                    of: find.byType(Pressable),
                    matching: find.byType(Opacity),
                  )
                  .first,
            )
            .opacity,
        1,
      );
      expect(
        tester
            .widget<Transform>(
              find
                  .descendant(
                    of: pillFade().first,
                    matching: find.byType(Transform),
                  )
                  .first,
            )
            .transform
            .storage[0],
        1,
      );
    });

    testWidgets('hiding again retracts and then removes it', (tester) async {
      await revealUpTo(tester, 1);
      await tester.pumpWidget(
        _app(returnMapPillForTest(visible: false, onTap: () {})),
      );
      await tester.pumpAndSettle();

      expect(find.byType(Pressable), findsNothing);
    });

    testWidgets('a tap calls back', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        _app(
          returnMapPillForTest(visible: true, onTap: () => taps++),
          reduced: true,
        ),
      );

      await tester.tap(find.byType(Pressable));

      expect(taps, 1);
    });
  });

  group('nearby row', () {
    const station = NearStationViewModel(
      type: NearStationType.bus,
      stationId: 'S1',
      stationName: '台北車站',
      lat: 25,
      lon: 121.5,
      walkingMinutes: 3,
      distanceMeters: 200,
    );

    Future<void> mount(WidgetTester tester) => tester.pumpWidget(
      _app(buildNearbyRowForTest(station: station, onStationTap: (_) {})),
    );

    testWidgets('a hairline at 30% opacity separates it from the row above', (
      tester,
    ) async {
      await mount(tester);

      final scheme = Theme.of(
        tester.element(find.byType(Pressable)),
      ).colorScheme;
      final decoration =
          tester
                  .widget<Container>(
                    find
                        .descendant(
                          of: find.byType(Pressable),
                          matching: find.byType(Container),
                        )
                        .first,
                  )
                  .decoration!
              as BoxDecoration;
      expect(
        decoration.border,
        Border(
          top: BorderSide(
            color: scheme.outlineVariant.withValues(alpha: 0.3),
            width: 0.5,
          ),
        ),
      );
    });

    testWidgets('the name and its details are set at 1.3 line height', (
      tester,
    ) async {
      await mount(tester);

      expect(tester.widget<Text>(find.text('台北車站')).style?.height, 1.3);
      final details = find.byWidgetPredicate(
        (w) => w is Text && (w.data ?? '').contains('3'),
      );
      expect(tester.widget<Text>(details).style?.height, 1.3);
    });
  });
}
