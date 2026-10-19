import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/shared/map/map_color_scheme.dart';

Future<String?> _styleFor(WidgetTester tester, Brightness brightness) async {
  String? style;
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(brightness: brightness),
      home: Builder(
        builder: (context) {
          style = mapStyleOf(context);
          return const SizedBox();
        },
      ),
    ),
  );
  return style;
}

void main() {
  testWidgets('dark theme yields the dark style JSON', (tester) async {
    final style = await _styleFor(tester, Brightness.dark);
    expect(style, isNotNull);
    expect(style, contains('#242f3e'));
  });

  testWidgets('light theme yields no style', (tester) async {
    expect(await _styleFor(tester, Brightness.light), isNull);
  });
}
