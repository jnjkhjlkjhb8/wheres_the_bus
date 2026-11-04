import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:wheres_the_bus/app/theme/app_text_styles.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/data/models/search_models.dart';
import 'package:wheres_the_bus/shared/motion/pressable.dart';
import 'package:wheres_the_bus/shared/widgets/search_result_row.dart';
import 'package:wheres_the_bus/shared/widgets/transport_icon.dart';

SearchResultViewData _data(
  AppSearchResultType type, {
  String title = '307',
  String subtitle = '板橋 — 撫遠街',
}) => SearchResultViewData(
  type: type,
  uid: 'u',
  title: title,
  subtitle: subtitle,
);

void main() {
  final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF3366CC));

  Future<void> mount(WidgetTester tester, Widget child, {double? width}) =>
      tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(colorScheme: scheme),
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(width: width ?? 400, child: child),
            ),
          ),
        ),
      );

  testWidgets('the preview rows carry their exact sample copy', (tester) async {
    await tester.pumpWidget(searchResultRowPreview());
    final rows = tester
        .widgetList<SearchResultRow>(find.byType(SearchResultRow))
        .map((row) => row.result)
        .toList();
    expect(
      [for (final r in rows) (r.type, r.uid, r.title, r.subtitle)],
      [
        (AppSearchResultType.busRoute, '307', '307', '板橋 — 撫遠街'),
        (
          AppSearchResultType.busStation,
          'stop-1',
          '台北車站(忠孝)',
          '忠孝西路一段',
        ),
        (AppSearchResultType.mrtStation, 'BL12', '台北車站', '板南線'),
        (
          AppSearchResultType.bikeStation,
          'bike-1',
          '捷運市政府站(3號出口)',
          '可借 12 / 可停 8',
        ),
        (AppSearchResultType.traStation, 'tra-1', '松山車站', '台鐵'),
        (AppSearchResultType.place, 'place-1', '台北101', ''),
      ],
    );
  });

  group('icon by result type', () {
    const expected = {
      AppSearchResultType.busRoute: TransportType.bus,
      AppSearchResultType.busStation: TransportType.busStop,
      AppSearchResultType.bikeStation: TransportType.bike,
      AppSearchResultType.traStation: TransportType.tra,
      AppSearchResultType.traTrain: TransportType.tra,
      AppSearchResultType.thsrStation: TransportType.thsr,
      AppSearchResultType.thsrTrain: TransportType.thsr,
      AppSearchResultType.mrtStation: TransportType.mrtBL,
      AppSearchResultType.place: TransportType.location,
    };
    for (final entry in expected.entries) {
      testWidgets('${entry.key.name} uses ${entry.value.name}', (tester) async {
        await mount(tester, SearchResultRow(result: _data(entry.key)));
        expect(
          tester.widget<TransportIcon>(find.byType(TransportIcon)).type,
          entry.value,
        );
      });
    }

    test('every result type is covered', () {
      expect(expected.keys.toSet(), AppSearchResultType.values.toSet());
    });
  });

  group('layout', () {
    testWidgets('is at least 60 tall, padded 12 by 8 and spaced by tokens', (
      tester,
    ) async {
      await mount(
        tester,
        SearchResultRow(result: _data(AppSearchResultType.busRoute)),
      );
      expect(tester.getSize(find.byType(SearchResultRow)).height, 60);
      final box = tester.widget<ConstrainedBox>(
        find
            .descendant(
              of: find.byType(SearchResultRow),
              matching: find.byType(ConstrainedBox),
            )
            .first,
      );
      expect(box.constraints.minHeight, 60);
      final padding = tester.widget<Padding>(
        find
            .ancestor(of: find.byType(Row), matching: find.byType(Padding))
            .first,
      );
      expect(
        padding.padding,
        const EdgeInsets.symmetric(
          horizontal: AppTheme.space12,
          vertical: AppTheme.space8,
        ),
      );
      final row = tester.widget<Row>(find.byType(Row));
      final gaps = row.children.whereType<SizedBox>().map((b) => b.width);
      expect(gaps, [AppTheme.space4, AppTheme.space8]);
    });

    testWidgets('title is a one-line heading, subtitle a secondary line', (
      tester,
    ) async {
      await mount(
        tester,
        SearchResultRow(result: _data(AppSearchResultType.busRoute)),
      );
      final title = tester.widget<Text>(find.text('307'));
      expect(title.maxLines, 1);
      expect(title.overflow, TextOverflow.ellipsis);
      expect(title.style?.fontSize, AppTextStyles.heading2.fontSize);
      final sub = tester.widget<Text>(find.text('板橋 — 撫遠街'));
      expect(sub.maxLines, 1);
      expect(sub.overflow, TextOverflow.ellipsis);
      expect(sub.style?.color, scheme.onSurfaceVariant);
      expect(sub.style?.fontSize, AppTextStyles.bodyRegular.fontSize);
      final column = tester.widget<Column>(find.byType(Column));
      expect(column.crossAxisAlignment, CrossAxisAlignment.start);
      expect(column.mainAxisAlignment, MainAxisAlignment.center);
      expect(column.mainAxisSize, MainAxisSize.min);
    });

    testWidgets('a place hides its subtitle even when it has one', (
      tester,
    ) async {
      await mount(
        tester,
        SearchResultRow(
          result: _data(AppSearchResultType.place, subtitle: '信義區'),
        ),
      );
      expect(find.text('信義區'), findsNothing);
      expect(find.text('307'), findsOneWidget);
    });

    testWidgets('an empty subtitle is not drawn for any type', (tester) async {
      await mount(
        tester,
        SearchResultRow(
          result: _data(AppSearchResultType.busStation, subtitle: ''),
        ),
      );
      expect(find.byType(Text), findsOneWidget);
    });

    testWidgets('other types show their subtitle', (tester) async {
      for (final type in AppSearchResultType.values) {
        if (type == AppSearchResultType.place) continue;
        await mount(tester, SearchResultRow(result: _data(type)));
        expect(find.text('板橋 — 撫遠街'), findsOneWidget, reason: type.name);
      }
    });

    testWidgets('ends in a 24 point insert arrow in the secondary tone', (
      tester,
    ) async {
      await mount(
        tester,
        SearchResultRow(result: _data(AppSearchResultType.busRoute)),
      );
      final icon = tester.widget<Icon>(
        find.byIcon(Symbols.arrow_insert_rounded),
      );
      expect(icon.size, 24);
      expect(icon.color, scheme.onSurfaceVariant);
    });

    testWidgets('a long title is cut to one line without overflowing', (
      tester,
    ) async {
      await mount(
        tester,
        SearchResultRow(
          result: _data(AppSearchResultType.busRoute, title: '很長的站名' * 20),
        ),
        width: 200,
      );
      expect(tester.takeException(), isNull);
      expect(tester.getSize(find.byType(SearchResultRow)).width, 200);
    });
  });

  group('interaction', () {
    testWidgets('a tap runs the callback', (tester) async {
      var taps = 0;
      await mount(
        tester,
        SearchResultRow(
          result: _data(AppSearchResultType.busRoute),
          onTap: () => taps++,
        ),
      );
      await tester.tap(find.byType(SearchResultRow));
      expect(taps, 1);
    });

    testWidgets('the row is announced by its title', (tester) async {
      await mount(
        tester,
        SearchResultRow(
          result: _data(AppSearchResultType.busRoute, title: '板橋站'),
          onTap: () {},
        ),
      );
      final semantics = tester.widget<Semantics>(
        find
            .descendant(
              of: find.byType(Pressable),
              matching: find.byType(Semantics),
            )
            .first,
      );
      expect(semantics.properties.label, '板橋站');
      expect(semantics.properties.button, isTrue);
    });
  });
}
