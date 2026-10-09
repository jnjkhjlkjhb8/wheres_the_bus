import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/core/errors/app_error.dart';
import 'package:wheres_the_bus/shared/widgets/error_state_view.dart';

import '../../support/helpers/i18n.dart';

void main() {
  Future<void> pump(WidgetTester tester, Widget child) => tester.pumpWidget(
    i18nApp(Scaffold(body: child)),
  );

  testWidgets('shows offline copy', (tester) async {
    await pump(
      tester,
      const ErrorStateView(error: OfflineError()),
    );
    expect(find.text('目前無法取得即時資訊'), findsOneWidget);
    expect(
      find.text('已離線,已儲存的資料仍可查看,連上網路後可取得即時資訊'),
      findsOneWidget,
    );
    expect(find.text('重試'), findsNothing);
  });

  testWidgets('retry button fires callback', (tester) async {
    var tapped = false;
    await pump(
      tester,
      ErrorStateView(
        error: const OfflineError(),
        onRetry: () => tapped = true,
      ),
    );
    await tester.tap(find.text('重試'));
    expect(tapped, isTrue);
  });

  testWidgets('lays out inside a sliver', (tester) async {
    await pump(
      tester,
      const CustomScrollView(
        slivers: [
          SliverToBoxAdapter(child: ErrorStateView(error: OfflineError())),
        ],
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('目前無法取得即時資訊'), findsOneWidget);
  });

  testWidgets('lays out as a ListView child', (tester) async {
    await pump(
      tester,
      ListView(
        children: const [ErrorStateView(error: OfflineError())],
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('目前無法取得即時資訊'), findsOneWidget);
  });
}
