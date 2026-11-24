import 'dart:async';

import 'package:flutter/services.dart';
import 'package:wheres_the_bus/data/repositories/settings_repository.dart';

/// Keeps Android's per-app language (Settings → Apps → 語言, Android 13+) and
/// the in-app language setting as one value instead of two that disagree.
///
/// Keys are the in-app ones (`system`, `zh`, `zh_CN`, `en`); the native side
/// speaks BCP-47 tags. Elsewhere (iOS, older Android, tests) both calls are
/// no-ops.
abstract final class SystemAppLanguage {
  static const channel = MethodChannel(
    'me.rabbitsayhello.wheresthebus/app_language',
  );

  static const _tags = {'zh': 'zh-TW', 'zh_CN': 'zh-CN', 'en': 'en'};

  /// Mirrors an in-app pick into the system setting.
  static Future<void> push(String key) => _invoke('set', _tags[key] ?? '');

  /// The system setting as an in-app key, or null when there is none to
  /// adopt (unsupported platform, or an unset system value).
  static Future<String?> pull() async {
    final tag = await _invoke('get');
    return tag is String ? keyFor(tag) : null;
  }

  /// A language chosen in Android's per-app setting while the app was closed
  /// wins over the stored one; the settings box listener then applies it.
  static Future<void> adopt(SettingsRepository settings) async {
    final key = await pull();
    if (key != null && key != settings.languageCode) {
      settings.languageCode = key;
    }
  }

  /// In-app key for a system tag; null for an empty or unsupported one.
  static String? keyFor(String tag) {
    final t = tag.toLowerCase();
    for (final (prefix, key) in _prefixes) {
      if (t.startsWith(prefix)) return key;
    }
    return null;
  }

  /// Most specific first: plain `zh` would also match the Simplified tags.
  static const _prefixes = [
    ('zh-cn', 'zh_CN'),
    ('zh-hans', 'zh_CN'),
    ('zh', 'zh'),
    ('en', 'en'),
  ];

  static Future<Object?> _invoke(String method, [Object? arguments]) async {
    try {
      return await channel.invokeMethod<Object?>(method, arguments);
    } on MissingPluginException {
      return null;
    }
  }
}
