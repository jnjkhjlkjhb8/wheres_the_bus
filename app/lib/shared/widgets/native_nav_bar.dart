import 'package:flutter/material.dart';
import 'package:wheres_the_bus/app/router/app_routes.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/widgets/ui_kit_host.dart';

/// A real UINavigationBar hosted as a platform view, so the back button and
/// title are the system's (Liquid Glass on iOS 26) rather than drawn to look
/// like it. iOS only; `DetailAppBar` decides when to use it.
class NativeNavBar extends StatelessWidget {
  const NativeNavBar({
    required this.title,
    this.subtitle,
    this.onBack,
    this.trailingWidth = 0,
    super.key,
  });

  final String title;
  final String? subtitle;
  final VoidCallback? onBack;

  /// Width the bar keeps clear at its trailing edge for widgets the caller
  /// lays over it; UIKit centres and truncates the title around it.
  final double trailingWidth;

  static const viewType = 'me.rabbitsayhello.wheresthebus/native_nav_bar';

  /// UIKit's own bar height.
  static const double height = 44;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return UiKitHost(
      viewType: viewType,
      params: {
        'title': title,
        'subtitle': subtitle,
        'backLabel': AppI18n.of(context).commonBack,
        'tint': cs.onSurface.toARGB32(),
        'dark': cs.brightness == Brightness.dark,
        'trailingWidth': trailingWidth,
      },
      onEvent: (method, _) {
        if (method == 'back') {
          (onBack ?? context.popOrHome)();
        }
      },
    );
  }
}
