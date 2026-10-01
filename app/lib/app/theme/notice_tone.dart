import 'package:flutter/material.dart';

import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/data/models/alert_models.dart';

typedef NoticeColors = ({Color background, Color ink, Color accent});

NoticeColors noticeColors(NoticeTone tone, ColorScheme cs) {
  final dark = cs.brightness == Brightness.dark;
  return switch (tone) {
    NoticeTone.critical =>
      dark
          ? (
              background: AppTheme.criticalBgDark,
              ink: AppTheme.criticalInkDark,
              accent: AppTheme.criticalAccentDark,
            )
          : (
              background: AppTheme.criticalBg,
              ink: AppTheme.criticalInkLight,
              accent: AppTheme.criticalAccent,
            ),
    NoticeTone.caution =>
      dark
          ? (
              background: AppTheme.warningBgDark,
              ink: AppTheme.warningInkDark,
              accent: AppTheme.warningAccentDark,
            )
          : (
              background: AppTheme.warningBg,
              ink: AppTheme.warningInkLight,
              accent: AppTheme.warningBorder,
            ),
    NoticeTone.info => (
      background: cs.surfaceContainerHighest,
      ink: cs.onSurface,
      accent: cs.onSurface,
    ),
    NoticeTone.neutral => (
      background: cs.surfaceContainerHighest,
      ink: cs.onSurface,
      accent: cs.onSurfaceVariant,
    ),
  };
}
