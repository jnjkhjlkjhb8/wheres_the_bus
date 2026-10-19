import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/shared/widgets/search_result_row.dart';

void main() {
  testWidgets('the preview shows one row of every kind with its sample data', (
    tester,
  ) async {
    await tester.pumpWidget(searchResultRowPreview());
    final rows = tester
        .widgetList<SearchResultRow>(find.byType(SearchResultRow))
        .map((r) => r.result)
        .toList();
    expect(rows.map((r) => r.uid), [
      '307',
      'stop-1',
      'BL12',
      'bike-1',
      'tra-1',
      'place-1',
    ]);
    expect(rows[3].subtitle, '可借 12 / 可停 8');
    expect(find.text('可借 12 / 可停 8'), findsOneWidget);
  });
}
