import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/app/theme/app_text_styles.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/shared/motion/pressable.dart';
import 'package:wheres_the_bus/shared/widgets/alight_track/alight_confirm_bar.dart';

import '../../support/helpers/haptic_log.dart';
import '../../support/helpers/i18n.dart';

const _medium = 'HapticFeedbackType.mediumImpact';

ColorScheme _scheme(WidgetTester tester) =>
    Theme.of(tester.element(find.byType(Scaffold))).colorScheme;

Future<void> _mount(WidgetTester tester, Widget bar) => tester.pumpWidget(
  i18nApp(Scaffold(body: Align(alignment: Alignment.bottomCenter, child: bar))),
);

Widget _confirm({
  String target = '板橋',
  int lead = 1,
  ValueChanged<int>? onLead,
  VoidCallback? onStart,
  VoidCallback? onCancel,
  VoidCallback? onRepick,
  Widget? binding,
  bool fromSearch = false,
  int leadMin = 0,
  int leadMax = 3,
  bool canStart = true,
  bool busy = false,
  String? errorText,
}) => AlightConfirmBar(
  targetName: target,
  lead: lead,
  onLeadChanged: onLead ?? (_) {},
  onStart: onStart ?? () {},
  onCancel: onCancel ?? () {},
  onRepick: onRepick,
  binding: binding,
  fromSearch: fromSearch,
  leadMin: leadMin,
  leadMax: leadMax,
  canStart: canStart,
  busy: busy,
  errorText: errorText,
);

Finder _step(IconData icon) => find.ancestor(
  of: find.byIcon(icon),
  matching: find.byType(Pressable),
);

void main() {
  group('binding chip', () {
    testWidgets('is a small tinted tag with a 12 point memo label', (
      tester,
    ) async {
      await _mount(tester, const AlightBindingChip(label: '1021 車'));
      final container = tester.widget<Container>(find.byType(Container));
      expect(
        container.padding,
        const EdgeInsets.symmetric(horizontal: AppTheme.space8, vertical: 3),
      );
      final decoration = container.decoration! as BoxDecoration;
      expect(decoration.color, _scheme(tester).surfaceContainerHighest);
      expect(
        decoration.borderRadius,
        BorderRadius.circular(AppTheme.radiusChip),
      );
      final text = tester.widget<Text>(find.text('1021 車'));
      expect(text.style?.fontSize, 12);
      expect(text.style?.fontFamily, AppTextStyles.memo.fontFamily);
    });
  });

  group('dock chrome', () {
    testWidgets('is a full width surface with a hairline top edge', (
      tester,
    ) async {
      await _mount(tester, _confirm());
      final scheme = _scheme(tester);
      final material = tester.widget<Material>(
        find.descendant(
          of: find.byType(AlightConfirmBar),
          matching: find.byType(Material),
        ).first,
      );
      expect(material.color, scheme.surface);
      final dock = tester.widget<Container>(
        find.descendant(
          of: find.byType(SafeArea),
          matching: find.byType(Container),
        ).first,
      );
      expect(dock.constraints?.maxWidth, double.infinity);
      expect(
        dock.padding,
        const EdgeInsets.fromLTRB(
          AppTheme.space16,
          AppTheme.space12,
          AppTheme.space16,
          AppTheme.space16,
        ),
      );
      final decoration = dock.decoration! as BoxDecoration;
      expect(decoration.color, scheme.surface);
      expect(
        decoration.border,
        Border(top: BorderSide(color: scheme.outlineVariant)),
      );
      final safe = tester.widget<SafeArea>(find.byType(SafeArea));
      expect(safe.top, isFalse);
      final column = tester.widget<Column>(
        find.descendant(of: find.byType(SafeArea), matching: find.byType(Column)).first,
      );
      expect(column.mainAxisSize, MainAxisSize.min);
      expect(column.crossAxisAlignment, CrossAxisAlignment.start);
    });
  });

  group('confirm bar rows', () {
    List<Widget> dockChildren(WidgetTester tester) => tester
        .widget<Column>(
          find
              .descendant(
                of: find.byType(SafeArea),
                matching: find.byType(Column),
              )
              .first,
        )
        .children;

    testWidgets('plain: picked line, gap, stepper, gap, start', (tester) async {
      await _mount(tester, _confirm());
      final children = dockChildren(tester);
      expect(children, hasLength(5));
      expect((children[1] as SizedBox).height, AppTheme.space12);
      expect((children[3] as SizedBox).height, AppTheme.space12);
    });

    testWidgets('a binding sits between the picked line and the stepper', (
      tester,
    ) async {
      await _mount(
        tester,
        _confirm(binding: const Text('binding', key: Key('binding'))),
      );
      final children = dockChildren(tester);
      expect(children, hasLength(7));
      expect((children[1] as SizedBox).height, AppTheme.space12);
      expect(children[2].key, const Key('binding'));
      expect((children[3] as SizedBox).height, AppTheme.space12);
    });

    testWidgets('an error sits 10 under the stepper in the error tone', (
      tester,
    ) async {
      await _mount(tester, _confirm(errorText: 'nope'));
      final children = dockChildren(tester);
      expect(children, hasLength(7));
      expect((children[3] as SizedBox).height, AppTheme.space10);
      final text = tester.widget<Text>(find.text('nope'));
      expect(text.style?.color, _scheme(tester).error);
      expect(text.style?.fontSize, AppTextStyles.bodySmall.fontSize);
    });
  });

  group('picked line', () {
    testWidgets('names the stop and offers both edits', (tester) async {
      var repicks = 0;
      var cancels = 0;
      await _mount(
        tester,
        _confirm(onRepick: () => repicks++, onCancel: () => cancels++),
      );
      expect(find.text(zhStrings.alightPickedStop('板橋')), findsOneWidget);
      await tester.tap(find.text(zhStrings.alightRepick));
      await tester.tap(find.byIcon(Icons.close_rounded));
      expect((repicks, cancels), (1, 1));
    });

    testWidgets('is a padded tinted pill that clips a long name', (
      tester,
    ) async {
      await _mount(tester, _confirm(target: '很長的站名' * 20));
      final scheme = _scheme(tester);
      final pill = tester.widget<Container>(
        find.ancestor(
          of: find.byIcon(Icons.close_rounded),
          matching: find.byType(Container),
        ).first,
      );
      expect(
        pill.padding,
        const EdgeInsets.symmetric(
          horizontal: AppTheme.space12,
          vertical: AppTheme.space6,
        ),
      );
      final decoration = pill.decoration! as BoxDecoration;
      expect(decoration.color, scheme.surfaceContainerHighest);
      expect(
        decoration.borderRadius,
        BorderRadius.circular(AppTheme.radiusButton),
      );
      final label = tester.widget<Text>(
        find.text(zhStrings.alightPickedStop('很長的站名' * 20)),
      );
      expect(label.maxLines, 1);
      expect(label.overflow, TextOverflow.ellipsis);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a stop from the rider search says where it came from', (
      tester,
    ) async {
      await _mount(tester, _confirm(fromSearch: true));
      expect(
        find.text(
          '${zhStrings.alightPickedStop('板橋')} ${zhStrings.alightFromSearch}',
        ),
        findsOneWidget,
      );
      await _mount(tester, _confirm());
      expect(find.textContaining(zhStrings.alightFromSearch), findsNothing);
    });

    testWidgets('without a repick handler there is no repick control', (
      tester,
    ) async {
      await _mount(tester, _confirm());
      expect(find.text(zhStrings.alightRepick), findsNothing);
    });

    testWidgets('repick and close are 44 point targets with their labels', (
      tester,
    ) async {
      await _mount(tester, _confirm(onRepick: () {}));
      final scheme = _scheme(tester);
      final pressables = tester.widgetList<Pressable>(
        find.descendant(
          of: find.byType(AlightConfirmBar),
          matching: find.byType(Pressable),
        ),
      ).toList();
      expect(pressables[0].semanticLabel, zhStrings.alightRepick);
      expect(pressables[0].minTapSize, 44);
      expect(pressables[1].semanticLabel, zhStrings.commonClose);
      expect(pressables[1].minTapSize, 44);
      final repick = tester.widget<Text>(find.text(zhStrings.alightRepick));
      expect(repick.style?.fontWeight, FontWeight.w600);
      expect(repick.style?.color, scheme.onSurface);
      final repickPadding = tester.widget<Padding>(
        find.ancestor(of: find.text(zhStrings.alightRepick), matching: find.byType(Padding)).first,
      );
      expect(
        repickPadding.padding,
        const EdgeInsets.symmetric(
          horizontal: AppTheme.space8,
          vertical: AppTheme.space6,
        ),
      );
      final close = tester.widget<Icon>(find.byIcon(Icons.close_rounded));
      expect(close.size, 18);
      expect(close.color, scheme.onSurfaceVariant);
      final closePadding = tester.widget<Padding>(
        find.ancestor(of: find.byIcon(Icons.close_rounded), matching: find.byType(Padding)).first,
      );
      expect(closePadding.padding, const EdgeInsets.all(AppTheme.space4));
    });
  });

  group('lead stepper', () {
    testWidgets('minus steps down, plus steps up', (tester) async {
      final seen = <int>[];
      await _mount(tester, _confirm(lead: 2, onLead: seen.add));
      await tester.tap(find.byIcon(Icons.remove_rounded));
      await tester.tap(find.byIcon(Icons.add_rounded));
      expect(seen, [1, 3]);
    });

    testWidgets('minus is dead at the floor, plus at the ceiling', (
      tester,
    ) async {
      final seen = <int>[];
      await _mount(
        tester,
        _confirm(lead: 1, leadMin: 1, leadMax: 1, onLead: seen.add),
      );
      await tester.tap(find.byIcon(Icons.remove_rounded));
      await tester.tap(find.byIcon(Icons.add_rounded));
      expect(seen, isEmpty);
      expect(tester.widget<Pressable>(_step(Icons.remove_rounded)).enabled, isFalse);
      expect(tester.widget<Pressable>(_step(Icons.add_rounded)).enabled, isFalse);
    });

    testWidgets('one inside either end keeps both live', (tester) async {
      await _mount(tester, _confirm(lead: 2, leadMin: 1, leadMax: 3));
      expect(tester.widget<Pressable>(_step(Icons.remove_rounded)).enabled, isTrue);
      expect(tester.widget<Pressable>(_step(Icons.add_rounded)).enabled, isTrue);
      await _mount(tester, _confirm(lead: 1, leadMin: 1, leadMax: 3));
      expect(tester.widget<Pressable>(_step(Icons.remove_rounded)).enabled, isFalse);
      expect(tester.widget<Pressable>(_step(Icons.add_rounded)).enabled, isTrue);
      await _mount(tester, _confirm(lead: 3, leadMin: 1, leadMax: 3));
      expect(tester.widget<Pressable>(_step(Icons.remove_rounded)).enabled, isTrue);
      expect(tester.widget<Pressable>(_step(Icons.add_rounded)).enabled, isFalse);
    });

    testWidgets('step buttons are 44 point outlined squares', (tester) async {
      await _mount(tester, _confirm(lead: 0, leadMin: 0, leadMax: 3));
      final scheme = _scheme(tester);
      final minus = tester.widget<Container>(
        find.descendant(of: _step(Icons.remove_rounded), matching: find.byType(Container)),
      );
      expect(
        tester.getSize(find.descendant(of: _step(Icons.remove_rounded), matching: find.byType(Container))),
        const Size(44, 44),
      );
      final decoration = minus.decoration! as BoxDecoration;
      expect(decoration.border, Border.all(color: scheme.outlineVariant));
      expect(
        decoration.borderRadius,
        BorderRadius.circular(AppTheme.radiusButton),
      );
      final disabled = tester.widget<Icon>(find.byIcon(Icons.remove_rounded));
      final live = tester.widget<Icon>(find.byIcon(Icons.add_rounded));
      expect(disabled.size, 20);
      expect(live.size, 20);
      expect(disabled.color, scheme.onSurfaceVariant);
      expect(live.color, scheme.onSurface);
      expect(
        tester.widget<Pressable>(_step(Icons.remove_rounded)).semanticLabel,
        zhStrings.commonDecrease,
      );
      expect(
        tester.widget<Pressable>(_step(Icons.add_rounded)).semanticLabel,
        zhStrings.commonIncrease,
      );
    });

    testWidgets('no lead says so and vibrates on the last stop only', (
      tester,
    ) async {
      await _mount(tester, _confirm(lead: 0));
      expect(find.text(zhStrings.alightNoLead('板橋')), findsOneWidget);
      expect(find.text(zhStrings.alightVibrateBoth), findsOneWidget);
      expect(find.text(zhStrings.alightVibrateLead), findsNothing);
      final hint = tester.widget<Text>(find.text(zhStrings.alightVibrateBoth));
      expect(hint.style?.color, _scheme(tester).onSurfaceVariant);
      expect(hint.style?.fontSize, AppTextStyles.bodyVerySmall.fontSize);
    });

    testWidgets('a lead reads as target, label and a stop count', (
      tester,
    ) async {
      await _mount(tester, _confirm(lead: 2));
      final rich = tester.widget<Text>(
        find.byWidgetPredicate((w) => w is Text && w.textSpan != null),
      );
      final span = rich.textSpan! as TextSpan;
      final parts = span.children!.cast<TextSpan>();
      expect(
        parts.map((p) => p.text),
        ['板橋', ' ', zhStrings.mrtAlightLeadLabel, ' ', zhStrings.stopsCount(2)],
      );
      expect(parts[0].style?.fontWeight, FontWeight.w700);
      expect(parts[2].style?.fontWeight, AppTextStyles.bodyRegular.fontWeight);
      expect(parts[4].style?.fontWeight, FontWeight.w600);
      expect(parts[4].style?.fontFamily, AppTextStyles.memo.fontFamily);
      expect(find.text(zhStrings.alightVibrateLead), findsOneWidget);
      expect(find.text(zhStrings.alightVibrateBoth), findsNothing);
      expect(find.text(zhStrings.alightNoLead('板橋')), findsNothing);
    });
  });

  group('start button', () {
    testWidgets('taps medium and starts', (tester) async {
      final haptics = captureHaptics();
      var starts = 0;
      await _mount(tester, _confirm(onStart: () => starts++));
      await tester.tap(find.text(zhStrings.mrtAlightStart));
      expect(starts, 1);
      expect(haptics, [_medium]);
    });

    testWidgets('is a 48 high ink bar with a bold surface label', (
      tester,
    ) async {
      await _mount(tester, _confirm());
      final scheme = _scheme(tester);
      final bar = find.ancestor(
        of: find.text(zhStrings.mrtAlightStart),
        matching: find.byType(Container),
      ).first;
      expect(tester.getSize(bar).height, 48);
      final decoration = tester.widget<Container>(bar).decoration! as BoxDecoration;
      expect(decoration.color, scheme.onSurface);
      expect(
        decoration.borderRadius,
        BorderRadius.circular(AppTheme.radiusButton),
      );
      final label = tester.widget<Text>(find.text(zhStrings.mrtAlightStart));
      expect(label.style?.fontWeight, FontWeight.w700);
      expect(label.style?.color, scheme.surface);
      expect(label.style?.fontSize, AppTextStyles.bodyLarge.fontSize);
      expect(
        tester.widget<Pressable>(
          find.ancestor(of: find.text(zhStrings.mrtAlightStart), matching: find.byType(Pressable)),
        ).semanticLabel,
        zhStrings.mrtAlightStart,
      );
    });

    testWidgets('an incomplete binding greys it out and blocks the tap', (
      tester,
    ) async {
      final haptics = captureHaptics();
      var starts = 0;
      await _mount(tester, _confirm(canStart: false, onStart: () => starts++));
      final scheme = _scheme(tester);
      final bar = find.ancestor(
        of: find.text(zhStrings.mrtAlightStart),
        matching: find.byType(Container),
      ).first;
      expect(
        (tester.widget<Container>(bar).decoration! as BoxDecoration).color,
        scheme.surfaceContainerHighest,
      );
      expect(
        tester.widget<Text>(find.text(zhStrings.mrtAlightStart)).style?.color,
        scheme.onSurfaceVariant,
      );
      await tester.tap(find.text(zhStrings.mrtAlightStart));
      expect(starts, 0);
      expect(haptics, isEmpty);
    });

    testWidgets('busy swaps the label for a 20 point spinner and blocks taps', (
      tester,
    ) async {
      var starts = 0;
      await _mount(tester, _confirm(busy: true, onStart: () => starts++));
      final scheme = _scheme(tester);
      expect(find.text(zhStrings.mrtAlightStart), findsNothing);
      final spinner = tester.widget<CircularProgressIndicator>(
        find.byType(CircularProgressIndicator),
      );
      expect(spinner.strokeWidth, 2.5);
      expect(spinner.color, scheme.surface);
      expect(
        tester.getSize(
          find.ancestor(
            of: find.byType(CircularProgressIndicator),
            matching: find.byType(SizedBox),
          ).first,
        ),
        const Size(20, 20),
      );
      final bar = find.ancestor(
        of: find.byType(CircularProgressIndicator),
        matching: find.byType(Container),
      ).first;
      expect(
        (tester.widget<Container>(bar).decoration! as BoxDecoration).color,
        scheme.surfaceContainerHighest,
      );
      await tester.tap(find.byType(CircularProgressIndicator), warnIfMissed: false);
      expect(starts, 0);
    });
  });

  group('manage bar', () {
    Widget manage({
      int lead = 2,
      String? bindingLabel,
      VoidCallback? onClose,
      VoidCallback? onCancel,
    }) => AlightManageBar(
      targetName: '板橋',
      lead: lead,
      onClose: onClose ?? () {},
      onCancel: onCancel ?? () {},
      bindingLabel: bindingLabel,
    );

    testWidgets('summarises the armed reminder in a tinted card', (
      tester,
    ) async {
      await _mount(tester, manage());
      final scheme = _scheme(tester);
      expect(find.text(zhStrings.alightArmedSummary('板橋', 2)), findsOneWidget);
      final card = tester.widget<Container>(
        find.ancestor(
          of: find.text(zhStrings.alightArmedSummary('板橋', 2)),
          matching: find.byType(Container),
        ).first,
      );
      expect(
        card.padding,
        const EdgeInsets.symmetric(
          horizontal: AppTheme.space12,
          vertical: AppTheme.space10,
        ),
      );
      final decoration = card.decoration! as BoxDecoration;
      expect(decoration.color, scheme.surfaceContainerHighest);
      expect(
        decoration.borderRadius,
        BorderRadius.circular(AppTheme.radiusButton),
      );
      expect(find.byType(AlightBindingChip), findsNothing);
    });

    testWidgets('names the followed vehicle 8 after the summary', (
      tester,
    ) async {
      await _mount(tester, manage(bindingLabel: 'KKA-1234'));
      expect(find.byType(AlightBindingChip), findsOneWidget);
      final summary = tester.getRect(
        find.text(zhStrings.alightArmedSummary('板橋', 2)),
      );
      final chip = tester.getRect(find.byType(AlightBindingChip));
      expect(chip.left - summary.right, greaterThanOrEqualTo(AppTheme.space8));
    });

    testWidgets('close is quiet, cancel is outlined and vibrates', (
      tester,
    ) async {
      final haptics = captureHaptics();
      var closes = 0;
      var cancels = 0;
      await _mount(
        tester,
        manage(onClose: () => closes++, onCancel: () => cancels++),
      );
      final scheme = _scheme(tester);
      BoxDecoration buttonDecoration(String label) =>
          tester.widget<Container>(
            find.ancestor(of: find.text(label), matching: find.byType(Container)).first,
          ).decoration! as BoxDecoration;
      expect(
        buttonDecoration(zhStrings.commonClose).border,
        Border.all(color: Colors.transparent),
      );
      expect(
        buttonDecoration(zhStrings.alightCancelReminder).border,
        Border.all(color: scheme.outlineVariant),
      );
      expect(
        tester.widget<Text>(find.text(zhStrings.commonClose)).style?.color,
        scheme.onSurfaceVariant,
      );
      expect(
        tester.widget<Text>(find.text(zhStrings.alightCancelReminder)).style?.color,
        scheme.onSurface,
      );
      expect(
        tester.getSize(find.ancestor(of: find.text(zhStrings.commonClose), matching: find.byType(Container)).first).height,
        44,
      );

      await tester.tap(find.text(zhStrings.commonClose));
      expect((closes, cancels), (1, 0));
      expect(haptics, isEmpty);
      await tester.tap(find.text(zhStrings.alightCancelReminder));
      expect((closes, cancels), (1, 1));
      expect(haptics, [_medium]);
    });

    testWidgets('the two buttons share the row, 10 apart', (tester) async {
      await _mount(tester, manage());
      final close = tester.getRect(
        find.ancestor(of: find.text(zhStrings.commonClose), matching: find.byType(Container)).first,
      );
      final cancel = tester.getRect(
        find.ancestor(of: find.text(zhStrings.alightCancelReminder), matching: find.byType(Container)).first,
      );
      expect(cancel.left - close.right, AppTheme.space10);
      expect(close.width, cancel.width);
    });

    testWidgets('a gap of 12 separates the summary from the buttons', (
      tester,
    ) async {
      await _mount(tester, manage());
      final children = tester
          .widget<Column>(
            find.descendant(of: find.byType(SafeArea), matching: find.byType(Column)).first,
          )
          .children;
      expect(children, hasLength(3));
      expect((children[1] as SizedBox).height, AppTheme.space12);
    });
  });
}
