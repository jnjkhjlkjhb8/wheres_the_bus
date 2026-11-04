import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/app/theme/app_text_styles.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/widgets/train_type_chip.dart';

void main() {
  const cases = {
    'EMU3000自強': TrainType.newTzeChiang,
    '3000': TrainType.newTzeChiang,
    ' 新自強號 ': TrainType.newTzeChiang,
    '區間快車': TrainType.localExpress,
    '區間車': TrainType.local,
    '普悠瑪自強': TrainType.puyuma,
    '太魯閣自強': TrainType.taroko,
    '自強號': TrainType.tzeChiang,
    '莒光號': TrainType.chuKuang,
    '高鐵': TrainType.thsr,
    ' mystery ': TrainType.other,
  };

  test('identifies overlapping labels in precedence order', () {
    for (final entry in cases.entries) {
      expect(TrainType.of(entry.key), entry.value, reason: entry.key);
    }
    expect(TrainType.of(''), TrainType.other);
  });

  testWidgets('all classes keep their canonical label and class color', (
    tester,
  ) async {
    for (final compact in [false, true]) {
      for (final entry in cases.entries) {
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.light,
            localizationsDelegates: AppI18n.localizationsDelegates,
            supportedLocales: AppI18n.supportedLocales,
            home: Scaffold(
              body: Center(
                child: TrainTypeChip(type: entry.key, compact: compact),
              ),
            ),
          ),
        );
        final context = tester.element(find.byType(TrainTypeChip));
        final i18n = AppI18n.of(context);
        final label = compact
            ? entry.value.compactLabelOf(i18n, entry.key)
            : entry.value.labelOf(i18n, entry.key);
        expect(find.text(label), findsOneWidget);
        expect(
          TrainTypeChip.canonicalLabel(i18n, entry.key),
          entry.value.labelOf(i18n, entry.key),
        );
        final container = tester.widget<Container>(
          find.descendant(
            of: find.byType(TrainTypeChip),
            matching: find.byType(Container),
          ),
        );
        expect(
          (container.decoration! as BoxDecoration).color,
          entry.value.color,
        );
        expect(
          container.padding,
          EdgeInsets.symmetric(
            horizontal: compact ? AppTheme.space6 : AppTheme.space12,
            vertical: compact ? AppTheme.space2 : 0,
          ),
        );
        if (!compact) {
          expect(tester.getSize(find.byType(TrainTypeChip)).height, 28);
        }
      }
    }
  });

  test('contrast ratio follows WCAG and is order independent', () {
    expect(
      TrainTypeChip.contrastRatio(Colors.black, Colors.white),
      closeTo(21, 1e-9),
    );
    expect(
      TrainTypeChip.contrastRatio(Colors.white, Colors.black),
      closeTo(21, 1e-9),
    );
    expect(
      TrainTypeChip.contrastRatio(Colors.white, Colors.white),
      closeTo(1, 1e-9),
    );
    // Grey 0x808080 has luminance ~0.2159: (1.05) / (0.2659).
    expect(
      TrainTypeChip.contrastRatio(Colors.white, const Color(0xFF808080)),
      closeTo(3.949, 0.01),
    );
  });

  test('label colour is whichever of dark and light reads better', () {
    expect(TrainTypeChip.labelColorFor(Colors.white), AppTheme.inkLight);
    expect(TrainTypeChip.labelColorFor(Colors.black), Colors.white);
  });

  test('a tie goes to the dark label', () {
    const dark = Color(0xFF444444);
    const light = Color(0x80444444);
    expect(
      TrainTypeChip.labelColorFor(Colors.grey, dark: dark, light: light),
      dark,
    );
  });

  testWidgets('the compact label tightens its line height', (tester) async {
    for (final compact in [false, true]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          localizationsDelegates: AppI18n.localizationsDelegates,
          supportedLocales: AppI18n.supportedLocales,
          home: Scaffold(
            body: Center(
              child: TrainTypeChip(type: '自強號', compact: compact),
            ),
          ),
        ),
      );
      final text = tester.widget<Text>(
        find.descendant(
          of: find.byType(TrainTypeChip),
          matching: find.byType(Text),
        ),
      );
      expect(
        text.style?.height,
        compact ? 1.2 : AppTextStyles.bodySmall.height,
      );
    }
  });
}
