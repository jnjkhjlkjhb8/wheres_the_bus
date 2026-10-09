import 'package:flutter/material.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';

class AppSearchBar extends StatelessWidget {
  const AppSearchBar({
    super.key,
    this.controller,
    this.hintText,
    this.onChanged,
    this.onTap,
    this.readOnly = false,
    this.autofocus = false,
    this.leading,
  });
  final TextEditingController? controller;

  /// Null takes the standard placeholder, which needs a locale to resolve —
  /// and a const default has no context to resolve it with.
  final String? hintText;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onTap;
  final bool readOnly;
  final bool autofocus;
  final Widget? leading;
  @override
  Widget build(BuildContext context) => SearchBar(
    controller: controller,
    hintText: hintText ?? AppI18n.of(context).commonSearch,
    onChanged: onChanged,
    onTap: onTap,
    readOnly: readOnly,
    autoFocus: autofocus,
    leading: leading ?? const Icon(Icons.search_rounded),
    elevation: const WidgetStatePropertyAll(0),
  );
}
