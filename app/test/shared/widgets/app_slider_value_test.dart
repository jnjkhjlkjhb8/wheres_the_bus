import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/app/theme/app_text_styles.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/shared/widgets/app_slider.dart';

void main() {
  final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF3366CC));

  Future<void> mount(WidgetTester tester, Widget child) => tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(colorScheme: scheme),
      home: Scaffold(
        body: Center(child: SizedBox(width: 300, child: child)),
      ),
    ),
  );

  testWidgets('the slider receives the range, steps and callback', (
    tester,
  ) async {
    void onChanged(double value) {}
    await mount(
      tester,
      AppSlider(
        value: 5,
        min: 2,
        max: 10,
        divisions: 8,
        onChanged: onChanged,
      ),
    );
    final slider = tester.widget<Slider>(find.byType(Slider));
    expect(slider.value, 5);
    expect(slider.min, 2);
    expect(slider.max, 10);
    expect(slider.divisions, 8);
    expect(slider.onChanged, same(onChanged));
  });

  testWidgets('a value past either end is held at that end', (tester) async {
    await mount(
      tester,
      const AppSlider(value: 99, min: 2, max: 10, onChanged: null),
    );
    expect(tester.widget<Slider>(find.byType(Slider)).value, 10);
    await mount(
      tester,
      const AppSlider(value: -99, min: 2, max: 10, onChanged: null),
    );
    expect(tester.widget<Slider>(find.byType(Slider)).value, 2);
  });

  testWidgets('without showValue the slider stands alone', (tester) async {
    await mount(tester, const AppSlider(value: 0.5, onChanged: null));
    expect(find.byType(Column), findsNothing);
    expect(find.byType(Text), findsNothing);
  });

  testWidgets('the bubble rides above the thumb position', (tester) async {
    for (final (value, expected) in [
      (0.0, -1.0),
      (0.25, -0.5),
      (0.5, 0.0),
      (1.0, 1.0),
    ]) {
      await mount(
        tester,
        AppSlider(value: value, showValue: true, onChanged: null),
      );
      final align = tester.widget<Align>(
        find
            .ancestor(of: find.byType(Text), matching: find.byType(Align))
            .first,
      );
      expect(align.alignment, Alignment(expected, 0), reason: '$value');
    }
  });

  testWidgets('a shifted range maps the value to its fraction', (tester) async {
    await mount(
      tester,
      const AppSlider(
        value: 5,
        min: 2,
        max: 10,
        showValue: true,
        onChanged: null,
      ),
    );
    final align = tester.widget<Align>(
      find.ancestor(of: find.byType(Text), matching: find.byType(Align)).first,
    );
    expect(align.alignment, const Alignment(-0.25, 0));
  });

  testWidgets('an out-of-range value pins the bubble to the end', (
    tester,
  ) async {
    await mount(
      tester,
      const AppSlider(
        value: 50,
        min: 2,
        max: 10,
        showValue: true,
        onChanged: null,
      ),
    );
    final align = tester.widget<Align>(
      find.ancestor(of: find.byType(Text), matching: find.byType(Align)).first,
    );
    expect(align.alignment, const Alignment(1, 0));
    await mount(
      tester,
      const AppSlider(
        value: -50,
        min: 2,
        max: 10,
        showValue: true,
        onChanged: null,
      ),
    );
    expect(
      tester
          .widget<Align>(
            find
                .ancestor(of: find.byType(Text), matching: find.byType(Align))
                .first,
          )
          .alignment,
      const Alignment(-1, 0),
    );
  });

  testWidgets('a continuous slider shows one decimal, a stepped one none', (
    tester,
  ) async {
    await mount(
      tester,
      const AppSlider(value: 0.46, showValue: true, onChanged: null),
    );
    expect(find.text('0.5'), findsOneWidget);
    await mount(
      tester,
      const AppSlider(
        value: 3.6,
        max: 10,
        divisions: 10,
        showValue: true,
        onChanged: null,
      ),
    );
    expect(find.text('4'), findsOneWidget);
  });

  testWidgets('the bubble is a small primary pill with tabular figures', (
    tester,
  ) async {
    await mount(
      tester,
      const AppSlider(value: 0.5, showValue: true, onChanged: null),
    );
    final bubble = tester.widget<Container>(
      find
          .ancestor(of: find.text('0.5'), matching: find.byType(Container))
          .first,
    );
    expect(
      bubble.padding,
      const EdgeInsets.symmetric(
        horizontal: AppTheme.space8,
        vertical: AppTheme.space2,
      ),
    );
    final decoration = bubble.decoration! as BoxDecoration;
    expect(decoration.color, scheme.primary);
    expect(decoration.borderRadius, BorderRadius.circular(4));
    final text = tester.widget<Text>(find.text('0.5'));
    expect(text.style?.color, scheme.onPrimary);
    expect(text.style?.fontSize, AppTextStyles.bodyVerySmall.fontSize);
    expect(text.style?.fontFeatures, const [FontFeature.tabularFigures()]);
    expect(
      tester.getRect(find.text('0.5')).center.dy,
      lessThan(tester.getRect(find.byType(Slider)).center.dy),
    );
  });

  testWidgets('a range centred on zero still maps by its width', (
    tester,
  ) async {
    await mount(
      tester,
      const AppSlider(
        value: 3,
        min: -3,
        max: 3,
        showValue: true,
        onChanged: null,
      ),
    );
    final align = tester.widget<Align>(
      find.ancestor(of: find.byType(Text), matching: find.byType(Align)).first,
    );
    expect(align.alignment, const Alignment(1, 0));
  });

  testWidgets('a zero-width range pins the bubble to the start', (
    tester,
  ) async {
    await mount(
      tester,
      const AppSlider(
        value: 5,
        min: 5,
        max: 5,
        showValue: true,
        onChanged: null,
      ),
    );
    final align = tester.widget<Align>(
      find.ancestor(of: find.byType(Text), matching: find.byType(Align)).first,
    );
    expect(align.alignment, const Alignment(-1, 0));
  });
}
