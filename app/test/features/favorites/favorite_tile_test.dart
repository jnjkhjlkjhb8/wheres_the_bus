import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/models/favorite.dart';
import 'package:wheres_the_bus/features/favorites/widgets/favorite_tile.dart';

void main() {
  testWidgets('tile draws a faint hairline and a tight title line height', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: FavoriteTile(
            fav: Favorite(
              type: FavoriteType.busStop,
              refId: 'a',
              title: '板橋站',
              subtitle: '新北市',
            ),
          ),
        ),
      ),
    );

    final cs = Theme.of(tester.element(find.byType(FavoriteTile))).colorScheme;
    final container = tester
        .widgetList<Container>(
          find.descendant(
            of: find.byType(FavoriteTile),
            matching: find.byType(Container),
          ),
        )
        .firstWhere(
          (c) =>
              c.decoration is BoxDecoration &&
              (c.decoration! as BoxDecoration).border != null,
        );
    final top =
        ((container.decoration! as BoxDecoration).border! as Border).top;
    expect(top.color, cs.outlineVariant.withValues(alpha: 0.3));
    expect(top.width, 0.5);
    // Same 16pt gutter as the home sheet's search bar and nearby rows.
    expect(
      container.padding,
      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    );
    expect(tester.widget<Text>(find.text('板橋站')).style!.height, 1.3);
  });
}
