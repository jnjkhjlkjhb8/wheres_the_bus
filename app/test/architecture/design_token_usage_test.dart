import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/app/theme/app_text_styles.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';

void main() {
  test('timeValue always carries tabular figures', () {
    // Digits that change width make a ticking countdown twitch. This is the one
    // property no caller may opt out of, so it is not a parameter.
    for (final style in [
      AppTextStyles.timeValue(),
      AppTextStyles.timeValue(size: 28, weight: FontWeight.w700),
      AppTextStyles.timeValue(color: const Color(0xFF111111), height: 1.1),
    ]) {
      expect(style.fontFeatures, AppTextStyles.tabularFigures);
      expect(style.fontFamily, AppTextStyles.memo.fontFamily);
    }
  });

  test('surfaceHighlight resolves one fill per brightness', () {
    expect(
      AppTheme.surfaceHighlight(Brightness.light),
      AppTheme.surfaceHighlightLight,
    );
    expect(
      AppTheme.surfaceHighlight(Brightness.dark),
      AppTheme.surfaceHighlightDark,
    );
  });

  test('no surface hand-rolls a time style or the highlight fill', () {
    final offenders = <String>[];
    final tabular = RegExp(
      r'AppTextStyles\.memo\.copyWith\((?:[^()]|\([^()]*\))*'
      r'fontFeatures:\s*(?:AppTextStyles\.)?(?:tabularFigures|const \[)',
      dotAll: true,
    );
    final highlightTernary = RegExp(
      r'AppTheme\.surfaceHighlightLight\s*\n?\s*:\s*AppTheme\.surfaceHighlightDark',
    );

    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      // The theme itself is where both recipes are allowed to be spelled out.
      if (entity.path.endsWith('app_text_styles.dart')) continue;
      if (entity.path.endsWith('app_theme.dart')) continue;
      final source = entity.readAsStringSync();
      if (tabular.hasMatch(source)) {
        offenders.add('${entity.path}: use AppTextStyles.timeValue(...)');
      }
      if (highlightTernary.hasMatch(source)) {
        offenders.add('${entity.path}: use AppTheme.surfaceHighlight(...)');
      }
    }

    expect(offenders, isEmpty, reason: offenders.join('\n'));
  });
}
