import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/shared/widgets/bottom_sheet_shell.dart';

void main() {
  // Text that sets no colour inherits the sheet Material's default; it used to
  // be Flutter's light onSurface, which made station titles dark-on-dark.
  for (final mode in ThemeMode.values.where((m) => m != ThemeMode.system)) {
    testWidgets('AppSheet text inherits the app onSurface in $mode', (t) async {
      late BuildContext inner;
      await t.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          darkTheme: AppTheme.dark,
          themeMode: mode,
          home: Scaffold(
            body: AppSheet(
              child: Builder(
                builder: (c) {
                  inner = c;
                  return const Text('x');
                },
              ),
            ),
          ),
        ),
      );

      expect(
        DefaultTextStyle.of(inner).style.color,
        Theme.of(inner).colorScheme.onSurface,
      );
    });
  }
}
