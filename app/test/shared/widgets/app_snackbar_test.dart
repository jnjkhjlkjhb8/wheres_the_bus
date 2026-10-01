import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/shared/widgets/app_snackbar.dart';

void main() {
  Future<void> tap(WidgetTester tester, void Function(BuildContext) onTap) =>
      tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => onTap(context),
                child: const Text('go'),
              ),
            ),
          ),
        ),
      );

  testWidgets('neutral shows the message with no leading icon', (tester) async {
    await tap(tester, (c) => AppSnackbar.show(c, '開發者模式已啟用'));
    await tester.tap(find.text('go'));
    await tester.pump();

    expect(find.text('開發者模式已啟用'), findsOneWidget);
    expect(find.byType(Icon), findsNothing);
  });

  testWidgets('success shows a leading icon', (tester) async {
    await tap(
      tester,
      (c) => AppSnackbar.show(c, '已抵達目的地', type: SnackType.success),
    );
    await tester.tap(find.text('go'));
    await tester.pump();

    expect(find.byIcon(Icons.check_circle_outline_rounded), findsOneWidget);
  });

  testWidgets('action tap invokes callback and dismisses the toast', (
    tester,
  ) async {
    var undone = false;
    await tap(
      tester,
      (c) => AppSnackbar.show(
        c,
        '已清除 3 則通知',
        action: '復原',
        onAction: () => undone = true,
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.text('復原'), findsOneWidget);

    await tester.tap(find.text('復原'));
    await tester.pumpAndSettle();

    expect(undone, isTrue);
    expect(find.text('已清除 3 則通知'), findsNothing);
  });

  testWidgets('an action does not make the pill a different component', (
    tester,
  ) async {
    final pill = find
        .ancestor(of: find.byType(Row), matching: find.byType(Container))
        .first;

    await tap(tester, (c) => AppSnackbar.show(c, '文湖線即將推出'));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    final plain = tester.getSize(pill).height;

    await tap(
      tester,
      (c) => AppSnackbar.show(c, '已移除收藏', action: '復原', onAction: () {}),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();

    expect(tester.getSize(pill).height, plain);
    // The action still clears the 44px tap-target floor by filling the pill.
    expect(
      tester
          .getSize(
            find
                .ancestor(
                  of: find.text('復原'),
                  matching: find.byType(ConstrainedBox),
                )
                .first,
          )
          .longestSide,
      greaterThanOrEqualTo(44),
    );
  });
}
