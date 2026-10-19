import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/app/theme/notice_tone.dart';
import 'package:wheres_the_bus/data/models/alert_models.dart';

void main() {
  test('notice text remains readable for every tone in both themes', () {
    for (final theme in [AppTheme.light, AppTheme.dark]) {
      for (final tone in NoticeTone.values) {
        final colors = noticeColors(tone, theme.colorScheme);
        final ink = colors.ink.computeLuminance();
        final background = colors.background.computeLuminance();
        final lighter = ink > background ? ink : background;
        final darker = ink > background ? background : ink;
        expect(
          (lighter + 0.05) / (darker + 0.05),
          greaterThanOrEqualTo(4.5),
          reason: '$tone ${theme.brightness} must keep body text readable',
        );
      }
    }
  });

  test('disabled content adapts to the neutral surface in each theme', () {
    final light = AppTheme.contentDisabled(Brightness.light);
    final dark = AppTheme.contentDisabled(Brightness.dark);
    expect(light, isNot(dark));
    expect(
      light.computeLuminance(),
      lessThan(AppTheme.lightScheme.surface.computeLuminance()),
    );
    expect(
      dark.computeLuminance(),
      greaterThan(AppTheme.darkScheme.surface.computeLuminance()),
    );
    expect(light.a, 1);
    expect(dark.a, 1);
  });

  for (final brightness in Brightness.values) {
    test('${brightness.name} urgent notices retain their semantic palette', () {
      final dark = brightness == Brightness.dark;
      final scheme = dark ? AppTheme.darkScheme : AppTheme.lightScheme;
      final critical = noticeColors(NoticeTone.critical, scheme);
      final caution = noticeColors(NoticeTone.caution, scheme);

      expect(
        critical.background,
        dark ? const Color(0xFF3B1512) : const Color(0xFFFDE7E4),
      );
      expect(
        critical.ink,
        dark ? const Color(0xFFFFD9D3) : const Color(0xFF7A1C13),
      );
      expect(
        critical.accent,
        dark ? const Color(0xFFF0705E) : const Color(0xFFB42318),
      );
      expect(
        caution.background,
        dark ? const Color(0xFF33230A) : const Color(0xFFFEF0C7),
      );
      expect(
        caution.ink,
        dark ? const Color(0xFFFBDFA6) : const Color(0xFF7A2E0E),
      );
      expect(
        caution.accent,
        dark ? const Color(0xFFE8912B) : const Color(0xFFB54708),
      );
    });
  }
}
