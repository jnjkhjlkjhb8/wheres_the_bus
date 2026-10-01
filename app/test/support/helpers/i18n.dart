import 'package:flutter/material.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/l10n/app_i18n_zh.dart';

MaterialApp i18nApp(Widget child, {Locale locale = const Locale('zh')}) =>
    MaterialApp(
      locale: locale,
      localizationsDelegates: AppI18n.localizationsDelegates,
      supportedLocales: AppI18n.supportedLocales,
      home: child,
    );

/// The zh-TW strings, for tests that assert on copy without a widget tree.
final AppI18n zhStrings = AppI18nZh();
