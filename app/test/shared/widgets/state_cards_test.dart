import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/widgets/state_cards.dart';

List<double?> _gaps(WidgetTester tester) => tester
    .widget<Column>(find.byType(Column))
    .children
    .whereType<SizedBox>()
    .map((box) => box.height)
    .toList();

void main() {
  final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF3366CC));

  Future<void> pump(WidgetTester tester, Widget child) => tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(colorScheme: scheme),
      locale: const Locale('zh'),
      localizationsDelegates: AppI18n.localizationsDelegates,
      supportedLocales: AppI18n.supportedLocales,
      home: Scaffold(body: Center(child: child)),
    ),
  );

  group('EmptyStateCard', () {
    testWidgets('shows the inbox icon at 48 in the outline tone', (
      tester,
    ) async {
      await pump(tester, const EmptyStateCard(message: '目前沒有班次'));
      final icon = tester.widget<Icon>(find.byType(Icon));
      expect(icon.icon, Icons.inbox_rounded);
      expect(icon.size, 48);
      expect(icon.color, scheme.outlineVariant);
    });

    testWidgets('accepts another icon', (tester) async {
      await pump(
        tester,
        const EmptyStateCard(message: 'm', icon: Icons.train),
      );
      expect(tester.widget<Icon>(find.byType(Icon)).icon, Icons.train);
    });

    testWidgets('centres the message at 14 in the secondary tone', (
      tester,
    ) async {
      await pump(tester, const EmptyStateCard(message: '目前沒有班次'));
      final text = tester.widget<Text>(find.text('目前沒有班次'));
      expect(text.textAlign, TextAlign.center);
      expect(text.style?.fontSize, 14);
      expect(text.style?.color, scheme.onSurfaceVariant);
    });

    testWidgets('spaces the card, its padding and its rows by token', (
      tester,
    ) async {
      await pump(tester, const EmptyStateCard(message: 'm'));
      expect(
        tester.widget<Card>(find.byType(Card)).margin,
        const EdgeInsets.all(AppTheme.space16),
      );
      final padding = tester.widget<Padding>(
        find
            .ancestor(
              of: find.byType(Column),
              matching: find.byType(Padding),
            )
            .first,
      );
      expect(padding.padding, const EdgeInsets.all(AppTheme.space32));
      final column = tester.widget<Column>(find.byType(Column));
      expect(column.mainAxisSize, MainAxisSize.min);
      expect(_gaps(tester), [AppTheme.space12]);
    });
  });

  group('ErrorStateCard', () {
    testWidgets('paints the card and icon in the error container tones', (
      tester,
    ) async {
      await pump(tester, const ErrorStateCard(message: 'failed'));
      final card = tester.widget<Card>(find.byType(Card));
      expect(card.color, scheme.errorContainer);
      expect(card.margin, const EdgeInsets.all(AppTheme.space16));
      final icon = tester.widget<Icon>(find.byType(Icon));
      expect(icon.icon, Icons.error_outline_rounded);
      expect(icon.size, 40);
      expect(icon.color, scheme.onErrorContainer);
    });

    testWidgets('centres the message at 14 in the on-container tone', (
      tester,
    ) async {
      await pump(tester, const ErrorStateCard(message: 'failed'));
      final text = tester.widget<Text>(find.text('failed'));
      expect(text.textAlign, TextAlign.center);
      expect(text.style?.fontSize, 14);
      expect(text.style?.color, scheme.onErrorContainer);
      final padding = tester.widget<Padding>(
        find
            .ancestor(
              of: find.byType(Column),
              matching: find.byType(Padding),
            )
            .first,
      );
      expect(padding.padding, const EdgeInsets.all(AppTheme.space16));
      expect(
        tester.widget<Column>(find.byType(Column)).mainAxisSize,
        MainAxisSize.min,
      );
    });

    testWidgets('offers no retry when there is nothing to retry', (
      tester,
    ) async {
      await pump(tester, const ErrorStateCard(message: 'failed'));
      expect(find.byType(FilledButton), findsNothing);
      expect(_gaps(tester), [AppTheme.space8]);
    });

    testWidgets('retry button runs the callback and wears the error tones', (
      tester,
    ) async {
      var retries = 0;
      await pump(
        tester,
        ErrorStateCard(message: 'failed', onRetry: () => retries++),
      );
      final button = find.byType(FilledButton);
      expect(button, findsOneWidget);
      expect(
        find.descendant(
          of: button,
          matching: find.text(
            lookupAppI18n(const Locale('zh')).commonRetryShort,
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: button,
          matching: find.byIcon(Icons.refresh_rounded),
        ),
        findsOneWidget,
      );
      final style = tester.widget<FilledButton>(button).style!;
      expect(style.backgroundColor?.resolve({}), scheme.error);
      expect(style.foregroundColor?.resolve({}), scheme.onError);
      expect(_gaps(tester), [AppTheme.space8, AppTheme.space12]);

      await tester.tap(button);
      expect(retries, 1);
    });
  });
}
