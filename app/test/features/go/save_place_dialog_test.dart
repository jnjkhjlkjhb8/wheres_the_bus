import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/app/theme/app_text_styles.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/features/go/model/saved_place_icons.dart';
import 'package:wheres_the_bus/features/go/widgets/save_place_dialog.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/motion/pressable.dart';
import 'package:wheres_the_bus/shared/widgets/app_button.dart';

typedef _Saved = ({String name, String iconKey});

void main() {
  final haptics = <String?>[];
  var results = <_Saved?>[];
  var closed = 0;

  setUp(() {
    haptics.clear();
    results = [];
    closed = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'HapticFeedback.vibrate') {
            haptics.add(call.arguments as String?);
          }
          return null;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Future<void> open(
    WidgetTester tester, {
    String initialName = 'Home',
    String? initialIcon,
    ThemeData? theme,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: theme ?? AppTheme.light,
        locale: const Locale('zh'),
        localizationsDelegates: AppI18n.localizationsDelegates,
        supportedLocales: AppI18n.supportedLocales,
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              final result = await showSavePlaceDialog(
                context,
                initialName: initialName,
                initialIcon: initialIcon,
              );
              results.add(result);
              closed++;
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  Finder tile(String key) => find.bySemanticsLabel(key);

  BoxDecoration tileDecoration(WidgetTester tester, String key) {
    final box = tester.widget<Container>(
      find.descendant(of: tile(key), matching: find.byType(Container)).first,
    );
    return box.decoration! as BoxDecoration;
  }

  Icon tileIcon(WidgetTester tester, String key) => tester.widget<Icon>(
    find.descendant(of: tile(key), matching: find.byType(Icon)),
  );

  FilledButton saveButton(WidgetTester tester) => tester.widget<FilledButton>(
    find.descendant(
      of: find.widgetWithText(AppButton, '儲存'),
      matching: find.byType(FilledButton),
    ),
  );

  testWidgets('shows the title, both labels and the prefilled name', (
    tester,
  ) async {
    await open(tester, initialName: 'Mom house');
    expect(find.text('儲存地點'), findsOneWidget);
    expect(find.text('名稱'), findsOneWidget);
    expect(find.text('圖示'), findsOneWidget);
    expect(find.text('Mom house'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).autofocus, isTrue);
    expect(find.text('取消'), findsOneWidget);
    expect(find.text('儲存'), findsOneWidget);
  });

  testWidgets('field labels use the small bold muted style', (tester) async {
    await open(tester);
    final cs = Theme.of(tester.element(find.byType(TextField))).colorScheme;
    for (final label in ['名稱', '圖示']) {
      final style = tester.widget<Text>(find.text(label)).style!;
      expect(style.color, cs.onSurfaceVariant);
      expect(style.fontWeight, FontWeight.w700);
      expect(style.fontSize, AppTextStyles.bodySmall.fontSize);
    }
  });

  testWidgets('the name field is styled and bordered by the theme', (
    tester,
  ) async {
    await open(tester);
    final cs = Theme.of(tester.element(find.byType(TextField))).colorScheme;
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.style!.color, cs.onSurface);
    expect(field.style!.fontWeight, FontWeight.w600);
    expect(field.style!.fontSize, AppTextStyles.bodyLarge.fontSize);
    expect(field.textInputAction, TextInputAction.done);
    final decoration = field.decoration!;
    expect(decoration.isDense, isTrue);
    expect(
      decoration.contentPadding,
      const EdgeInsets.symmetric(
        horizontal: AppTheme.space14,
        vertical: AppTheme.space12,
      ),
    );
    final enabled = decoration.enabledBorder! as OutlineInputBorder;
    expect(
      enabled.borderRadius,
      BorderRadius.circular(AppTheme.radiusButton),
    );
    expect(enabled.borderSide.color, cs.outlineVariant);
    final focused = decoration.focusedBorder! as OutlineInputBorder;
    expect(
      focused.borderRadius,
      BorderRadius.circular(AppTheme.radiusButton),
    );
    expect(focused.borderSide.color, cs.onSurface);
    expect(focused.borderSide.width, 2);
  });

  testWidgets('vertical rhythm between the form rows', (tester) async {
    await open(tester);
    double gap(Finder above, Finder below) =>
        tester.getTopLeft(below).dy - tester.getBottomLeft(above).dy;

    final field = find.byType(TextField);
    final nameLabel = find.text('名稱');
    final iconLabel = find.text('圖示');
    final firstTile = tile(SavedPlaceIcons.keys.first);
    final cancel = find.widgetWithText(AppButton, '取消');

    expect(gap(nameLabel, field), AppTheme.space8);
    expect(gap(field, iconLabel), 18);
    expect(gap(iconLabel, firstTile), AppTheme.space10);
    final grid = find.byType(Wrap);
    expect(gap(grid, cancel), AppTheme.space20);
    final save = find.widgetWithText(AppButton, '儲存');
    expect(
      tester.getTopLeft(save).dx - tester.getTopRight(cancel).dx,
      AppTheme.space12,
    );
  });

  testWidgets('every saved-place icon is offered, spaced by the theme', (
    tester,
  ) async {
    await open(tester);
    final wrap = tester.widget<Wrap>(find.byType(Wrap));
    expect(wrap.spacing, AppTheme.space10);
    expect(wrap.runSpacing, AppTheme.space10);
    for (final key in SavedPlaceIcons.keys) {
      expect(tile(key), findsOneWidget);
      expect(tileIcon(tester, key).icon, SavedPlaceIcons.resolve(key));
      expect(tileIcon(tester, key).size, 22);
      final size = tester.getSize(
        find.descendant(of: tile(key), matching: find.byType(Container)).first,
      );
      expect(size, const Size(48, 48));
    }
  });

  testWidgets('without an initial icon the first key is selected', (
    tester,
  ) async {
    await open(tester);
    final cs = Theme.of(tester.element(find.byType(TextField))).colorScheme;
    final first = SavedPlaceIcons.keys.first;
    final selected = tileDecoration(tester, first);
    expect(selected.color, cs.surface);
    expect(selected.borderRadius, BorderRadius.circular(AppTheme.radiusCard));
    expect((selected.border! as Border).top.color, cs.onSurface);
    expect((selected.border! as Border).top.width, 1.5);
    expect(tileIcon(tester, first).color, cs.onSurface);

    final other = tileDecoration(tester, SavedPlaceIcons.keys[1]);
    expect(other.color, cs.surfaceContainerHighest);
    expect(other.borderRadius, BorderRadius.circular(AppTheme.radiusCard));
    expect((other.border! as Border).top.color, Colors.transparent);
    expect((other.border! as Border).top.width, 1.5);
    expect(
      tileIcon(tester, SavedPlaceIcons.keys[1]).color,
      cs.onSurfaceVariant,
    );
  });

  testWidgets('an initial icon starts selected instead of the first key', (
    tester,
  ) async {
    await open(tester, initialIcon: 'school');
    final cs = Theme.of(tester.element(find.byType(TextField))).colorScheme;
    expect(tileDecoration(tester, 'school').color, cs.surface);
    expect(tileDecoration(tester, 'home').color, cs.surfaceContainerHighest);
    await tester.tap(find.widgetWithText(AppButton, '儲存'));
    await tester.pumpAndSettle();
    expect(results, [(name: 'Home', iconKey: 'school')]);
  });

  testWidgets('tapping an icon moves the selection and is returned', (
    tester,
  ) async {
    await open(tester);
    final cs = Theme.of(tester.element(find.byType(TextField))).colorScheme;
    await tester.tap(tile('star'));
    await tester.pumpAndSettle();
    expect(tileDecoration(tester, 'star').color, cs.surface);
    expect(tileIcon(tester, 'star').color, cs.onSurface);
    expect(
      tileDecoration(tester, SavedPlaceIcons.keys.first).color,
      cs.surfaceContainerHighest,
    );
    await tester.tap(find.widgetWithText(AppButton, '儲存'));
    await tester.pumpAndSettle();
    expect(results, [(name: 'Home', iconKey: 'star')]);
  });

  testWidgets('saving returns the trimmed name and taps lightly', (
    tester,
  ) async {
    await open(tester, initialName: '  Gym  ');
    await tester.tap(find.widgetWithText(AppButton, '儲存'));
    await tester.pumpAndSettle();
    expect(results, [(name: 'Gym', iconKey: SavedPlaceIcons.keys.first)]);
    expect(haptics, ['HapticFeedbackType.lightImpact']);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('the keyboard done action saves like the button', (
    tester,
  ) async {
    await open(tester);
    await tester.enterText(find.byType(TextField), 'Office');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(results, [(name: 'Office', iconKey: SavedPlaceIcons.keys.first)]);
  });

  testWidgets('a blank name disables saving and ignores the keyboard', (
    tester,
  ) async {
    await open(tester, initialName: '');
    expect(saveButton(tester).onPressed, isNull);
    await tester.enterText(find.byType(TextField), '   ');
    await tester.pump();
    expect(saveButton(tester).onPressed, isNull);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(closed, 0);
    expect(haptics, isEmpty);
    expect(find.byType(TextField), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'Park');
    await tester.pump();
    expect(saveButton(tester).onPressed, isNotNull);
    await tester.enterText(find.byType(TextField), '');
    await tester.pump();
    expect(saveButton(tester).onPressed, isNull);
  });

  testWidgets('cancel returns null without a haptic', (tester) async {
    await open(tester);
    await tester.tap(find.widgetWithText(AppButton, '取消'));
    await tester.pumpAndSettle();
    expect(results, [null]);
    expect(haptics, isEmpty);
  });

  testWidgets('icon tiles are pressable with their key as label', (
    tester,
  ) async {
    await open(tester);
    expect(
      find.descendant(of: find.byType(Wrap), matching: find.byType(Pressable)),
      findsNWidgets(SavedPlaceIcons.keys.length),
    );
  });
}
