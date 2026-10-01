import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/shared/widgets/route_tab_bar.dart';

void main() {
  Widget host(Brightness brightness, TabController controller) => MaterialApp(
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: Colors.blue,
        brightness: brightness,
      ),
    ),
    home: Scaffold(
      body: RouteTabBar(
        controller: controller,
        tabs: const ['A', 'B'],
        raised: true,
      ),
    ),
  );

  Color barColor(WidgetTester tester) => tester
      .widget<ColoredBox>(
        find.descendant(
          of: find.byType(RouteTabBar),
          matching: find.byType(ColoredBox),
        ),
      )
      .color;

  testWidgets('raised bar tracks the active theme brightness', (tester) async {
    final controller = TabController(length: 2, vsync: tester);
    addTearDown(controller.dispose);

    await tester.pumpWidget(host(Brightness.light, controller));
    await tester.pumpAndSettle();
    final lightBar = barColor(tester);
    expect(
      lightBar,
      ColorScheme.fromSeed(
        seedColor: Colors.blue,
      ).surfaceContainerLow,
    );

    await tester.pumpWidget(host(Brightness.dark, controller));
    await tester.pumpAndSettle();
    final darkBar = barColor(tester);
    expect(
      darkBar,
      ColorScheme.fromSeed(
        seedColor: Colors.blue,
        brightness: Brightness.dark,
      ).surfaceContainerLow,
    );

    expect(lightBar, isNot(darkBar));
  });
}
