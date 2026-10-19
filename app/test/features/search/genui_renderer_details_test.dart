import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/models/bus_models.dart';
import 'package:wheres_the_bus/data/models/search_models.dart';
import 'package:wheres_the_bus/features/search/genui/model/genui_node.dart';
import 'package:wheres_the_bus/features/search/genui/view/genui_renderer.dart';
import 'package:wheres_the_bus/shared/motion/app_motion.dart';

import '../../support/helpers/i18n.dart';

const _stop = SearchResult(
  type: SearchResultType.busStation,
  uid: 'STOP1',
  name: '台北車站',
  subtitle: '台北市',
  city: 'Taipei',
);

Future<void> _pump(
  WidgetTester tester,
  List<GenUiNode> nodes, {
  Map<String, SearchResult> refs = const {},
  StopEtaSource? etaSource,
}) => tester.pumpWidget(
  i18nApp(
    Scaffold(
      body: SingleChildScrollView(
        child: GenUiRenderer(
          nodes: nodes,
          refs: refs,
          onAsk: (_) {},
          onOpen: (_) {},
          etaSource: etaSource ?? (_) => const Stream.empty(),
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets('a chip with a result points outward, a bare chip searches', (
    tester,
  ) async {
    await _pump(
      tester,
      const [
        GenUiChip(label: 'open', query: 'q', refUid: 'STOP1'),
        GenUiChip(label: 'ask', query: 'q'),
      ],
      refs: const {'STOP1': _stop},
    );
    await tester.pumpAndSettle();
    Finder iconIn(String label) => find.descendant(
      of: find.ancestor(of: find.text(label), matching: find.byType(Row)).first,
      matching: find.byType(Icon),
    );
    expect(
      tester.widget<Icon>(iconIn('open')).icon,
      Icons.arrow_outward_rounded,
    );
    expect(tester.widget<Icon>(iconIn('ask')).icon, Icons.search_rounded);
  });

  testWidgets('only a resolved route card carries a chevron', (tester) async {
    await _pump(
      tester,
      const [
        GenUiRoute(title: 'bare', badges: []),
      ],
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.chevron_right_rounded), findsNothing);

    await _pump(
      tester,
      const [
        GenUiRoute(title: 'bare', badges: [], refUid: 'STOP1'),
      ],
      refs: const {'STOP1': _stop},
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.chevron_right_rounded), findsOneWidget);
  });

  testWidgets('leaving the screen cancels the live arrival stream', (
    tester,
  ) async {
    final controller = StreamController<List<BusStopArrival>>();
    addTearDown(controller.close);
    await _pump(
      tester,
      const [
        GenUiRoute(title: 'stop', badges: [], refUid: 'STOP1'),
      ],
      refs: const {'STOP1': _stop},
      etaSource: (_) => controller.stream,
    );
    await tester.pump();
    expect(controller.hasListener, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(controller.hasListener, isFalse);
  });

  testWidgets('rows stagger in 30ms apart and settle in place', (
    tester,
  ) async {
    await _pump(
      tester,
      const [GenUiText('a'), GenUiText('b'), GenUiText('c')],
    );
    double opacityOf(String text) => tester
        .widget<Opacity>(
          find
              .ancestor(of: find.text(text), matching: find.byType(Opacity))
              .first,
        )
        .opacity;
    double lift(String text) => tester
        .widget<Transform>(
          find
              .ancestor(of: find.text(text), matching: find.byType(Transform))
              .first,
        )
        .transform
        .getTranslation()
        .y;

    expect(opacityOf('a'), 0);
    expect(lift('a'), 4);

    // Row 0 lasts exactly the base duration; row 2 starts 60ms late and so
    // is still on its way when row 0 is done.
    await tester.pump(AppMotion.medium);
    expect(opacityOf('a'), 1);
    expect(opacityOf('c'), inExclusiveRange(0, 1));

    await tester.pumpAndSettle();
    for (final row in ['a', 'b', 'c']) {
      expect(opacityOf(row), 1);
      expect(lift(row), 0);
    }
  });
}
