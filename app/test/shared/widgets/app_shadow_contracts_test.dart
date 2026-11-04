import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/app/theme/app_shadows.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/shared/widgets/app_bars.dart';
import 'package:wheres_the_bus/shared/widgets/app_card.dart';

void main() {
  const cardKey = ValueKey('elevated-card');

  Future<BoxDecoration> renderCard(
    WidgetTester tester,
    ThemeData theme,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: const Scaffold(
          body: Center(
            child: SizedBox(
              width: 320,
              child: AppCard(key: cardKey, child: Text('Route details')),
            ),
          ),
        ),
      ),
    );
    expect(find.text('Route details'), findsOneWidget);
    final card = tester.widget<Container>(
      find.descendant(
        of: find.byKey(cardKey),
        matching: find.byType(Container),
      ),
    );
    return card.decoration! as BoxDecoration;
  }

  testWidgets('light elevated card paints a visible ambient shadow', (
    tester,
  ) async {
    final decoration = await renderCard(tester, AppTheme.light);
    expect(decoration.boxShadow, isNotEmpty);
    for (final shadow in decoration.boxShadow!) {
      expect(shadow.color.a, greaterThan(0));
      expect(shadow.blurRadius, greaterThan(0));
    }
    expect(decoration.border, isNull);
    expect(decoration.color, isNot(AppTheme.light.scaffoldBackgroundColor));
  });

  testWidgets('dark elevated card uses a surface step without a shadow', (
    tester,
  ) async {
    final decoration = await renderCard(tester, AppTheme.dark);
    expect(decoration.boxShadow, isEmpty);
    expect(decoration.border, isNull);
    expect(decoration.color, const Color(0xFF1C1C1C));
    expect(decoration.color, isNot(AppTheme.dark.scaffoldBackgroundColor));
  });

  testWidgets('floating control paints a visible ambient shadow', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: const Scaffold(
          body: Center(
            child: AppBarCircleButton(child: Icon(Icons.close_rounded)),
          ),
        ),
      ),
    );
    expect(find.byIcon(Icons.close_rounded), findsOneWidget);
    final control = tester.widget<Container>(
      find.descendant(
        of: find.byType(AppBarCircleButton),
        matching: find.byType(Container),
      ),
    );
    final decoration = control.decoration! as BoxDecoration;
    expect(decoration.boxShadow, isNotEmpty);
    for (final shadow in decoration.boxShadow!) {
      expect(shadow.color.a, greaterThan(0));
      expect(shadow.blurRadius, greaterThan(0));
    }
  });

  test('bottom-sheet preset retains two visible finite ambient layers', () {
    const layers = AppShadows.bottomSheet;
    expect(layers, hasLength(2));
    for (final layer in layers) {
      expect(layer.color.a, greaterThan(0));
      expect(layer.blurRadius, greaterThan(0));
      expect(layer.blurRadius.isFinite, isTrue);
      expect(layer.spreadRadius.isFinite, isTrue);
      expect(layer.offset.dx.isFinite, isTrue);
      expect(layer.offset.dy.isFinite, isTrue);
    }
  });

  test('segment thumb shadow tightens and strengthens in dark mode', () {
    final light = AppShadows.segmentThumbFor(Brightness.light).single;
    final dark = AppShadows.segmentThumbFor(Brightness.dark).single;
    expect(light.blurRadius, 4);
    expect(light.offset, const Offset(0, 2));
    expect(light.color.a, closeTo(.05, .005));
    expect(dark.blurRadius, 2);
    expect(dark.offset, const Offset(0, 1));
    expect(dark.color.a, closeTo(.25, .005));
  });

  test('lifted shadow follows the gesture opacity', () {
    final shadow = AppShadows.lifted(.3).single;
    expect(shadow.color.a, closeTo(.3, .005));
    expect(shadow.blurRadius, 24);
    expect(shadow.offset, const Offset(0, 8));
  });

  test('scrolled-under shadow is the surface colour, not black', () {
    const surface = Color(0xFF123456);
    final shadow = AppShadows.scrolledUnder(surface).single;
    expect(shadow.color, surface);
    expect(shadow.blurRadius, 12);
    expect(shadow.offset, const Offset(0, 6));
  });
}
