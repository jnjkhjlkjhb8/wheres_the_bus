import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/app/theme/app_text_styles.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/shared/widgets/divider_line.dart';

void main() {
  final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF3366CC));

  Future<void> pump(WidgetTester tester, Widget child) => tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(colorScheme: scheme),
      home: Scaffold(
        body: Center(child: SizedBox(width: 300, child: child)),
      ),
    ),
  );

  testWidgets('a divider line is a hairline in the outline tone', (
    tester,
  ) async {
    await pump(tester, const DividerLine());
    final divider = tester.widget<Divider>(find.byType(Divider));
    expect(divider.height, 0.5);
    expect(divider.thickness, 0.5);
    expect(divider.color, scheme.outlineVariant);
    expect(tester.getSize(find.byType(Divider)).height, 0.5);
  });

  testWidgets('a labelled divider sets the label between two lines', (
    tester,
  ) async {
    await pump(tester, const AppLabeledDivider(label: '或'));
    expect(find.byType(DividerLine), findsNWidgets(2));
    final label = tester.widget<Text>(find.text('或'));
    expect(label.style?.color, scheme.onSurfaceVariant);
    expect(label.style?.fontSize, AppTextStyles.bodySmall.fontSize);
    expect(label.style?.fontWeight, AppTextStyles.bodySmall.fontWeight);

    final padding = tester.widget<Padding>(
      find.ancestor(of: find.text('或'), matching: find.byType(Padding)).first,
    );
    expect(
      padding.padding,
      const EdgeInsets.symmetric(horizontal: AppTheme.space8),
    );
    final labelWidth = tester.getSize(find.text('或')).width;
    final lineWidths = tester
        .widgetList<Divider>(find.byType(Divider))
        .map((d) => tester.getSize(find.byWidget(d)).width)
        .toList();
    expect(lineWidths, hasLength(2));
    expect(lineWidths[0], lineWidths[1]);
    expect(
      lineWidths[0] * 2 + labelWidth + AppTheme.space8 * 2,
      closeTo(300, 0.001),
    );
  });
}
