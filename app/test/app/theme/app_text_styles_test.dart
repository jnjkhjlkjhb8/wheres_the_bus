import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/app/theme/app_text_styles.dart';

void main() {
  test('reading styles keep the single UI font family', () {
    for (final style in [
      AppTextStyles.heading1,
      AppTextStyles.heading2,
      AppTextStyles.bodyLarge,
      AppTextStyles.bodyRegular,
      AppTextStyles.bodySmall,
      AppTextStyles.bodyVerySmall,
    ]) {
      expect(style.fontFamily, 'IBMPlexSans');
      expect(
        style.fontWeight,
        isIn([
          FontWeight.w400,
          FontWeight.w600,
          FontWeight.w700,
        ]),
      );
      final painter = TextPainter(
        text: TextSpan(text: '下一班公車\nNext arrival', style: style),
        textDirection: TextDirection.ltr,
      );
      try {
        painter.layout(maxWidth: 320);
        expect(painter.computeLineMetrics().length, greaterThanOrEqualTo(2));
        expect(painter.height, greaterThan(style.fontSize!));
        expect(painter.height.isFinite, isTrue);
      } finally {
        painter.dispose();
      }
    }
  });

  test('screen headings tighten tracking while small captions stay open', () {
    expect(AppTextStyles.heading1.fontSize, 24);
    expect(AppTextStyles.heading1.fontWeight, FontWeight.w700);
    expect(AppTextStyles.heading1.height, 1.3);
    expect(AppTextStyles.heading1.letterSpacing, lessThan(0));
    expect(AppTextStyles.heading1.letterSpacing!.abs(), lessThan(1));
    expect(AppTextStyles.heading2.fontSize, 18);
    expect(AppTextStyles.heading2.fontWeight, FontWeight.w600);
    expect(AppTextStyles.heading2.height, 1.3);
    for (final style in [
      AppTextStyles.bodySmall,
      AppTextStyles.bodyVerySmall,
    ]) {
      expect(style.letterSpacing, greaterThan(0));
      expect(style.letterSpacing, lessThan(1));
    }
  });

  test('default time values use stable mono figures and reading metrics', () {
    final style = AppTextStyles.timeValue();

    expect(style.fontFamily, 'IBMPlexMono');
    expect(style.fontSize, 13);
    expect(style.fontWeight, FontWeight.w400);
    expect(style.height, 1.4);
    expect(style.fontFeatures, contains(const FontFeature.tabularFigures()));
  });

  test(
    'time emphasis preserves caller choices without changing later defaults',
    () {
      final original = AppTextStyles.timeValue();
      final emphasized = AppTextStyles.timeValue(
        size: 32,
        weight: FontWeight.w700,
        color: const Color(0xFF111111),
        decoration: TextDecoration.underline,
        height: 1.5,
        letterSpacing: 0.2,
      );

      expect(emphasized.fontFamily, 'IBMPlexMono');
      expect(emphasized.fontSize, 32);
      expect(emphasized.fontWeight, FontWeight.w700);
      expect(emphasized.color, const Color(0xFF111111));
      expect(emphasized.decoration, TextDecoration.underline);
      expect(emphasized.height, 1.5);
      expect(emphasized.letterSpacing, 0.2);
      expect(
        emphasized.fontFeatures,
        contains(const FontFeature.tabularFigures()),
      );
      expect(AppTextStyles.timeValue(), original);
    },
  );
}
