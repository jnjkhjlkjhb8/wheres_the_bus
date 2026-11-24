import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:wheres_the_bus/app/router/app_routes.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';

/// Publishes the home-screen quick actions (long-press the app icon) and
/// opens the one the rider picks.
///
/// Titles are set from here rather than from the native bundles so they follow
/// the in-app language setting, not only the device's. Android shortcuts
/// carry a `wheresthebus://` intent and arrive through the ordinary deep-link
/// path; iOS reports the pick on [channel] (`open` while running, `pending`
/// for the one that launched the app).
class HomeShortcuts extends StatefulWidget {
  const HomeShortcuts({required this.router, required this.child, super.key});

  final GoRouter router;
  final Widget child;

  static const channel = MethodChannel(
    'me.rabbitsayhello.wheresthebus/home_shortcuts',
  );

  @override
  State<HomeShortcuts> createState() => _HomeShortcutsState();
}

class _HomeShortcutsState extends State<HomeShortcuts> {
  List<Map<String, String>> _sent = const [];

  @override
  void initState() {
    super.initState();
    HomeShortcuts.channel.setMethodCallHandler((call) async {
      if (call.method == 'open') _open(call.arguments);
    });
    unawaited(_invoke('pending').then(_open));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final i18n = AppI18n.of(context);
    final items = [
      {'path': AppRoutes.search, 'title': i18n.commonSearch, 'icon': 'search'},
      {
        'path': AppRoutes.favorites,
        'title': i18n.favoritesTitle,
        'icon': 'bookmark',
      },
    ];
    // Flat string maps, so their printed form is a full comparison.
    if ('$items' == '$_sent') return;
    _sent = items;
    unawaited(_invoke('set', items));
  }

  /// Only app-internal paths: the value round-trips through the OS.
  void _open(Object? path) {
    if (path is String && path.startsWith('/')) widget.router.go(path);
  }

  /// Platforms without the native side (tests, desktop) just have no
  /// shortcuts.
  static Future<Object?> _invoke(String method, [Object? arguments]) async {
    try {
      return await HomeShortcuts.channel.invokeMethod<Object?>(
        method,
        arguments,
      );
    } on MissingPluginException {
      return null;
    }
  }

  @override
  void dispose() {
    HomeShortcuts.channel.setMethodCallHandler(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
