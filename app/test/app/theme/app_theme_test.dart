import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/shared/widgets/app_bars.dart';
import 'package:wheres_the_bus/shared/widgets/state_cards.dart';
import 'package:wheres_the_bus/shared/widgets/transit_timeline.dart';

Map<String, TextStyle> readingRoles(TextTheme text) => {
  'displayLarge': text.displayLarge!,
  'headlineLarge': text.headlineLarge!,
  'titleLarge': text.titleLarge!,
  'titleMedium': text.titleMedium!,
  'titleSmall': text.titleSmall!,
  'bodyLarge': text.bodyLarge!,
  'bodyMedium': text.bodyMedium!,
  'bodySmall': text.bodySmall!,
  'labelLarge': text.labelLarge!,
  'labelMedium': text.labelMedium!,
  'labelSmall': text.labelSmall!,
};

void main() {
  concentricRadiusTests();
  for (final brightness in Brightness.values) {
    final dark = brightness == Brightness.dark;
    final name = brightness.name;
    ThemeData theme() => dark ? AppTheme.dark : AppTheme.light;

    test('$name text roles lay out readable multiline content', () {
      for (final role in readingRoles(theme().textTheme).entries) {
        final style = role.value;
        expect(style.fontSize, greaterThan(0), reason: role.key);
        expect(style.fontSize!.isFinite, isTrue, reason: role.key);
        expect(style.height, inInclusiveRange(1, 2), reason: role.key);
        expect(style.fontFamily, 'IBMPlexSans', reason: role.key);
        final painter = TextPainter(
          text: TextSpan(text: '下一班公車\nNext arrival', style: style),
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: 320);
        try {
          final lines = painter.computeLineMetrics();
          expect(lines.length, greaterThanOrEqualTo(2), reason: role.key);
          expect(
            painter.height,
            greaterThan(style.fontSize!),
            reason: role.key,
          );
          for (final line in lines) {
            expect(line.height, greaterThan(0), reason: role.key);
            expect(line.height.isFinite, isTrue, reason: role.key);
          }
        } finally {
          painter.dispose();
        }
      }
    });

    test('$name headings tighten while small labels retain open tracking', () {
      final text = theme().textTheme;
      for (final style in [text.displayLarge!, text.titleLarge!]) {
        expect(style.fontSize, greaterThanOrEqualTo(20));
        expect(style.letterSpacing, lessThan(0));
        expect(style.letterSpacing!.abs(), lessThan(style.fontSize! * 0.05));
      }
      expect(
        text.displayLarge!.fontSize,
        greaterThan(text.titleLarge!.fontSize!),
      );
      for (final style in [
        text.bodySmall!,
        text.labelMedium!,
        text.labelSmall!,
      ]) {
        expect(style.letterSpacing, greaterThan(0));
        expect(style.letterSpacing, lessThan(1));
      }
    });

    test('$name semantic surface and subdued content match design roles', () {
      expect(
        AppTheme.surfaceHighlight(brightness),
        dark ? const Color(0xFF333333) : const Color(0xFFE8E8E8),
      );
      expect(
        AppTheme.contentDisabled(brightness),
        dark ? const Color(0xFF717171) : const Color(0xFFA6A6A6),
      );
      expect(
        AppTheme.inkTertiary(brightness),
        dark ? const Color(0xFF8C8C8C) : const Color(0xFF868686),
      );
    });

    testWidgets('$name Material card paints its elevated surface', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: theme(),
          home: const Scaffold(body: EmptyStateCard(message: '目前沒有班次')),
        ),
      );
      expect(find.text('目前沒有班次'), findsOneWidget);
      final material = tester.widget<Material>(
        find.descendant(of: find.byType(Card), matching: find.byType(Material)),
      );
      expect(material.color, dark ? const Color(0xFF1C1C1C) : Colors.white);
      expect(material.elevation, greaterThan(0));
      expect(tester.getSize(find.byType(Card)).height, greaterThan(0));
      expect(tester.takeException(), isNull);
    });

    testWidgets('$name floating control and passed timeline stay legible', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: theme(),
          home: const Scaffold(
            body: Column(
              children: [
                AppBarCircleButton(child: Icon(Icons.close_rounded)),
                SizedBox(
                  height: 56,
                  child: TimelineSpine(
                    kind: TimelineNodeKind.terminus,
                    dimmed: true,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      final control = tester.widget<Container>(
        find.descendant(
          of: find.byType(AppBarCircleButton),
          matching: find.byType(Container),
        ),
      );
      final decoration = control.decoration! as BoxDecoration;
      expect(decoration.color, dark ? const Color(0xFF282828) : Colors.white);
      expect(decoration.boxShadow, dark ? isEmpty : isNotEmpty);
      expect(decoration.border, dark ? isNotNull : isNull);
      final node = tester
          .widgetList<Container>(
            find.descendant(
              of: find.byType(TimelineSpine),
              matching: find.byType(Container),
            ),
          )
          .singleWhere((container) => container.decoration is BoxDecoration);
      expect(
        (node.decoration! as BoxDecoration).color,
        dark ? const Color(0xFF8C8C8C) : const Color(0xFF868686),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('$name primary button retains its 44px tappable height', (
      tester,
    ) async {
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: theme(),
          home: Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => taps++,
                child: const Text('搭乘此班'),
              ),
            ),
          ),
        ),
      );
      expect(
        tester.getSize(find.byType(FilledButton)).height,
        greaterThanOrEqualTo(44),
      );
      expect(tester.getSize(find.byType(FilledButton)).width, greaterThan(0));
      await tester.tap(find.byType(FilledButton));
      expect(taps, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('$name hairline divider retains nonnegative geometry', (
      tester,
    ) async {
      final data = theme();
      expect(data.dividerTheme.thickness, greaterThanOrEqualTo(0));
      expect(data.dividerTheme.space, greaterThanOrEqualTo(0));
      await tester.pumpWidget(
        MaterialApp(
          theme: data,
          home: const Scaffold(body: Divider()),
        ),
      );
      expect(
        tester.getSize(find.byType(Divider)).height,
        greaterThanOrEqualTo(0),
      );
      expect(tester.takeException(), isNull);
    });
  }

  for (final platform in [TargetPlatform.iOS, TargetPlatform.macOS]) {
    for (final reduced in [false, true]) {
      testWidgets('${platform.name} navigation flight reduced=$reduced', (
        tester,
      ) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.light.copyWith(platform: platform),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
              child: child!,
            ),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => unawaited(
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const Scaffold(
                          body: Align(
                            alignment: Alignment.topLeft,
                            child: Text('目的站', key: ValueKey('detail-title')),
                          ),
                        ),
                      ),
                    ),
                  ),
                  child: const Text('選擇目的站'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('選擇目的站'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        final flight = tester.getRect(
          find.byKey(const ValueKey('detail-title')),
        );
        if (reduced) {
          expect(flight.left, closeTo(0, 0.01));
        } else {
          expect(flight.left, greaterThan(0));
        }
        await tester.pumpAndSettle();
        expect(find.text('目的站'), findsOneWidget);
        expect(
          tester.getRect(find.byKey(const ValueKey('detail-title'))).left,
          closeTo(0, 0.01),
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
}

void concentricRadiusTests() {
  group('AppTheme.concentric', () {
    test('subtracts the inset from the outer radius', () {
      expect(AppTheme.concentric(12, 4), 8);
    });
    test('never goes negative', () {
      expect(AppTheme.concentric(12, 20), 0);
    });
    test('zero inset keeps the outer radius', () {
      expect(AppTheme.concentric(12, 0), 12);
    });
  });
}
