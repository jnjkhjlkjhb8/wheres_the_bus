import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/shared/motion/app_motion.dart';
import 'package:wheres_the_bus/shared/motion/pressable.dart';
import 'package:wheres_the_bus/shared/widgets/station_display_field.dart';

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

  final textStyle = find.descendant(
    of: find.byType(StationDisplayField),
    matching: find.byType(AnimatedDefaultTextStyle),
  );

  AnimatedContainer box(WidgetTester tester) =>
      tester.widget<AnimatedContainer>(find.byType(AnimatedContainer));

  BoxDecoration decoration(WidgetTester tester) =>
      box(tester).decoration! as BoxDecoration;

  testWidgets('is a 90 by 76 rounded tile by default', (tester) async {
    await mount(
      tester,
      const StationDisplayField(value: '台北', active: false),
    );
    expect(tester.getSize(find.byType(AnimatedContainer)), const Size(90, 76));
    expect(decoration(tester).borderRadius, BorderRadius.circular(8));
    expect(box(tester).alignment, Alignment.center);
    expect(box(tester).curve, AppMotion.easeOut);
  });

  testWidgets('takes the size it is given', (tester) async {
    await mount(
      tester,
      const StationDisplayField(
        value: '台北',
        active: false,
        width: 120,
        height: 50,
      ),
    );
    expect(tester.getSize(find.byType(AnimatedContainer)), const Size(120, 50));
  });

  testWidgets('inactive is a quiet surface with on-surface text', (
    tester,
  ) async {
    await mount(
      tester,
      const StationDisplayField(value: '台北', active: false),
    );
    expect(decoration(tester).color, scheme.surfaceContainerHighest);
    expect(
      tester
          .widget<DefaultTextStyle>(
            find
                .ancestor(
                  of: find.text('台北'),
                  matching: find.byType(DefaultTextStyle),
                )
                .first,
          )
          .style
          .color,
      scheme.onSurface,
    );
  });

  testWidgets('active is the primary tone with on-primary text', (
    tester,
  ) async {
    await mount(
      tester,
      const StationDisplayField(value: '台北', active: true),
    );
    expect(decoration(tester).color, scheme.primary);
    final style = tester.widget<AnimatedDefaultTextStyle>(textStyle);
    expect(style.style.color, scheme.onPrimary);
    expect(style.style.fontSize, 32);
    expect(style.style.fontWeight, FontWeight.w500);
    expect(style.style.fontFamily, 'IBMPlexSans');
    expect(style.curve, AppMotion.easeOut);
  });

  testWidgets('the value scales down to fit and keeps 10 side padding', (
    tester,
  ) async {
    await mount(
      tester,
      const StationDisplayField(value: '新北產業園區新北', active: false),
    );
    final fitted = tester.widget<FittedBox>(find.byType(FittedBox));
    expect(fitted.fit, BoxFit.scaleDown);
    final padding = tester.widget<Padding>(
      find.ancestor(of: textStyle, matching: find.byType(Padding)).first,
    );
    expect(
      padding.padding,
      const EdgeInsets.symmetric(horizontal: AppTheme.space10),
    );
    expect(tester.getSize(find.byType(FittedBox)).width, lessThanOrEqualTo(90));
  });

  testWidgets('animates over the short duration, or not at all when reduced', (
    tester,
  ) async {
    await mount(
      tester,
      const StationDisplayField(value: '台北', active: false),
    );
    expect(box(tester).duration, AppMotion.short);
    expect(
      tester.widget<AnimatedDefaultTextStyle>(textStyle).duration,
      AppMotion.short,
    );
    await mount(
      tester,
      const StationDisplayField(value: '台北', active: false),
      reduced: true,
    );
    expect(box(tester).duration, Duration.zero);
    expect(
      tester.widget<AnimatedDefaultTextStyle>(textStyle).duration,
      Duration.zero,
    );
  });

  testWidgets('without a tap handler it is not pressable', (tester) async {
    await mount(
      tester,
      const StationDisplayField(value: '台北', active: false),
    );
    expect(find.byType(Pressable), findsNothing);
  });

  testWidgets('with a tap handler it presses, labels itself and fires', (
    tester,
  ) async {
    var taps = 0;
    await mount(
      tester,
      StationDisplayField(value: '台北', active: false, onTap: () => taps++),
    );
    final pressable = tester.widget<Pressable>(find.byType(Pressable));
    expect(pressable.semanticLabel, '台北');
    await tester.tap(find.byType(Pressable));
    expect(taps, 1);
  });
}
