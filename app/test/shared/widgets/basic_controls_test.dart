import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/shared/widgets/app_accordion.dart';
import 'package:wheres_the_bus/shared/widgets/app_card.dart';
import 'package:wheres_the_bus/shared/widgets/app_input.dart';
import 'package:wheres_the_bus/shared/widgets/app_range_slider.dart';
import 'package:wheres_the_bus/shared/widgets/app_slider.dart';
import 'package:wheres_the_bus/shared/widgets/app_switch.dart';

void main() {
  Future<void> mount(
    WidgetTester tester,
    Widget child, {
    bool reduced = false,
  }) => tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light,
      home: Scaffold(
        body: MediaQuery(
          data: MediaQueryData(disableAnimations: reduced),
          child: Center(child: SizedBox(width: 400, child: child)),
        ),
      ),
    ),
  );

  testWidgets('card variants retain their surface and outlined boundary', (
    tester,
  ) async {
    final colors = AppTheme.light.colorScheme;
    for (final (card, color, outlined) in [
      (
        const AppCard(child: Text('elevated')),
        colors.surfaceContainerLow,
        false,
      ),
      (
        const AppCard.filled(child: Text('filled')),
        colors.surfaceContainerHighest,
        false,
      ),
      (
        const AppCard.outlined(
          padding: EdgeInsets.all(7),
          child: Text('outlined'),
        ),
        colors.surfaceContainerLow,
        true,
      ),
    ]) {
      await mount(tester, card);
      final container = tester.widget<Container>(
        find.descendant(
          of: find.byType(AppCard),
          matching: find.byType(Container),
        ),
      );
      final decoration = container.decoration! as BoxDecoration;
      expect(decoration.color, color);
      expect(decoration.border, outlined ? isNotNull : isNull);
      expect(
        container.padding,
        outlined ? const EdgeInsets.all(7) : const EdgeInsets.all(16),
      );
    }
  });

  testWidgets(
    'sliders clamp their thumb, format discrete values and forward changes',
    (tester) async {
      double? changed;
      await mount(
        tester,
        AppSlider(
          value: 2,
          showValue: true,
          onChanged: (value) => changed = value,
        ),
      );
      expect(tester.widget<Slider>(find.byType(Slider)).value, 1);
      expect(find.text('2.0'), findsOneWidget);
      await tester.drag(find.byType(Slider), const Offset(-100, 0));
      expect(changed, isNotNull);
      expect(changed, inInclusiveRange(0, 1));
      await mount(
        tester,
        const AppSlider(
          value: -1,
          divisions: 4,
          showValue: true,
          onChanged: null,
        ),
      );
      expect(tester.widget<Slider>(find.byType(Slider)).value, 0);
      expect(find.text('-1'), findsOneWidget);
      await mount(
        tester,
        const AppSlider(
          value: 0,
          max: 0,
          showValue: true,
          onChanged: null,
        ),
      );
      expect(
        tester.widget<Align>(find.byType(Align).last).alignment,
        Alignment.centerLeft,
      );
      await mount(tester, const AppSlider(value: 0.5, onChanged: null));
      expect(find.byType(Slider), findsOneWidget);
      expect(find.text('0.5'), findsNothing);
    },
  );

  testWidgets('range sliders clamp both ends and carry discrete labels', (
    tester,
  ) async {
    await mount(
      tester,
      const AppRangeSlider(
        values: RangeValues(-2, 4),
        divisions: 4,
        onChanged: null,
      ),
    );
    var range = tester.widget<RangeSlider>(find.byType(RangeSlider));
    expect(range.values, const RangeValues(0, 1));
    expect(range.labels, const RangeLabels('0', '1'));
    await mount(
      tester,
      const AppRangeSlider(values: RangeValues(0.2, 0.8), onChanged: null),
    );
    range = tester.widget<RangeSlider>(find.byType(RangeSlider));
    expect(range.values, const RangeValues(0.2, 0.8));
    expect(range.labels, isNull);
  });

  testWidgets('input errors replace helper copy and preserve typed values', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    String? changed;
    await mount(
      tester,
      AppInput(
        label: '站名',
        hint: '輸入站名',
        helper: '搜尋附近',
        controller: controller,
        maxLines: null,
        minLines: 2,
        onChanged: (value) => changed = value,
      ),
    );
    await tester.enterText(find.byType(TextField), '台北');
    expect(changed, '台北');
    var input = tester.widget<TextField>(find.byType(TextField));
    expect(input.decoration!.alignLabelWithHint, isTrue);
    expect(input.decoration!.helperText, '搜尋附近');
    await mount(
      tester,
      AppInput(
        label: '站名',
        helper: '搜尋附近',
        error: '請重試',
        controller: controller,
        prefixIcon: const Icon(Icons.search),
        suffixIcon: const Icon(Icons.clear),
      ),
    );
    input = tester.widget<TextField>(find.byType(TextField));
    expect(input.decoration!.helperText, isNull);
    expect(input.decoration!.errorText, '請重試');
    expect(input.decoration!.alignLabelWithHint, isFalse);
    expect(controller.text, '台北');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'accordion contents follow taps with ordinary and reduced motion',
    (tester) async {
      for (final reduced in [false, true]) {
        await mount(
          tester,
          AppAccordion(
            key: ValueKey(reduced),
            title: '票價',
            child: const Text('全票 15 元'),
          ),
          reduced: reduced,
        );
        expect(find.text('全票 15 元'), findsNothing);
        await tester.tap(find.text('票價'));
        await tester.pumpAndSettle();
        expect(find.text('全票 15 元'), findsOneWidget);
        expect(
          tester.widget<AnimatedRotation>(find.byType(AnimatedRotation)).turns,
          0.5,
        );
        await tester.tap(find.text('票價'));
        await tester.pumpAndSettle();
        expect(find.text('全票 15 元'), findsNothing);
      }
    },
  );

  testWidgets(
    'labeled switches toggle from the label and disabled controls stay inert',
    (tester) async {
      bool? changed;
      await mount(
        tester,
        AppSwitch(
          value: false,
          label: '提醒',
          onChanged: (value) => changed = value,
        ),
      );
      await tester.tap(find.text('提醒'));
      expect(changed, isTrue);
      changed = null;
      await mount(
        tester,
        const AppSwitch(value: true, label: '停用', onChanged: null),
      );
      await tester.tap(find.text('停用'));
      expect(changed, isNull);
      await mount(tester, const AppSwitch(value: false, onChanged: null));
      expect(find.byType(Switch), findsOneWidget);
      expect(find.text('停用'), findsNothing);
    },
  );

  testWidgets('a labeled switch reads as one toggle with its label', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await mount(
      tester,
      AppSwitch(value: true, label: '提醒', onChanged: (_) {}),
    );

    expect(
      tester.getSemantics(find.byType(Switch)),
      matchesSemantics(
        label: '提醒',
        hasToggledState: true,
        isToggled: true,
        hasEnabledState: true,
        isEnabled: true,
        isFocusable: true,
        hasTapAction: true,
        hasFocusAction: true,
      ),
    );
    handle.dispose();
  });
}
