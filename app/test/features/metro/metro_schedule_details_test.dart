import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/data/models/metro_models.dart';
import 'package:wheres_the_bus/data/repositories/mrt_repository.dart';
import 'package:wheres_the_bus/features/metro/bloc/metro_eta_state.dart';
import 'package:wheres_the_bus/features/metro/view/metro_station_detail_view.dart';

import '../../support/helpers/i18n.dart';
import '../../support/metro_station_harness.dart';

class _Quiet extends MrtRepository {
  @override
  Stream<MetroLiveArrival> eta(String system, String stationId) =>
      const Stream.empty();

  @override
  Future<List<MetroScheduleEntry>> schedule(
    String system,
    String stationId,
  ) async => const [];
}

MetroSchedule _row(String line, String to) => MetroSchedule(
  line: line,
  destination: to,
  firstTime: '06:00',
  lastTime: '23:30',
);

Future<void> _pumpSection(
  WidgetTester tester,
  List<MetroSchedule> schedule, {
  bool loading = false,
}) => tester.pumpWidget(
  i18nApp(
    Scaffold(
      body: SingleChildScrollView(
        child: MetroScheduleSection(schedule: schedule, loading: loading),
      ),
    ),
  ),
);

Finder _headers() => find.byWidgetPredicate(
  (w) => w.runtimeType.toString() == '_ScheduleLineHeader',
);

void main() {
  testWidgets('dividers are 1px hairlines at half-strength outline', (
    tester,
  ) async {
    await _pumpSection(tester, [_row('R', 'A'), _row('R', 'B')]);
    final cs = Theme.of(tester.element(find.byType(Divider).first)).colorScheme;
    final dividers = tester.widgetList<Divider>(find.byType(Divider)).toList();
    expect(dividers, hasLength(2));
    for (final d in dividers) {
      expect(d.height, 1);
      expect(d.thickness, 1);
      expect(d.color, cs.outlineVariant.withValues(alpha: 0.5));
    }
  });

  testWidgets('the loading table uses the same hairline', (tester) async {
    await _pumpSection(tester, const [], loading: true);
    final cs = Theme.of(tester.element(find.byType(Divider).first)).colorScheme;
    final dividers = tester.widgetList<Divider>(find.byType(Divider)).toList();
    expect(dividers, hasLength(2));
    for (final d in dividers) {
      expect(d.color, cs.outlineVariant.withValues(alpha: 0.5));
    }
  });

  testWidgets('a single line has no headers and a divider between rows', (
    tester,
  ) async {
    await _pumpSection(tester, [_row('R', 'A'), _row('R', 'B')]);
    expect(_headers(), findsNothing);
    final rowA = tester.getRect(find.textContaining('A').first);
    final rowB = tester.getRect(find.textContaining('B').first);
    final between = tester
        .widgetList<Divider>(find.byType(Divider))
        .toList()
        .length;
    expect(between, 2);
    final divider = tester.getRect(find.byType(Divider).last);
    expect(divider.top, greaterThan(rowA.bottom));
    expect(divider.bottom, lessThan(rowB.top));
  });

  testWidgets('interchange groups get one header each, the first tighter', (
    tester,
  ) async {
    await _pumpSection(tester, [
      _row('R', 'A'),
      _row('R', 'B'),
      _row('G', 'C'),
    ]);
    final headers = tester.widgetList(_headers()).toList();
    expect(headers, hasLength(2));
    expect((headers[0] as dynamic).first, isTrue);
    expect((headers[1] as dynamic).first, isFalse);
    double topPadding(Element header) => tester
        .widget<Padding>(
          find
              .descendant(
                of: find.byWidget(header.widget),
                matching: find.byType(Padding),
              )
              .first,
        )
        .padding
        .resolve(TextDirection.ltr)
        .top;
    final elements = _headers().evaluate().toList();
    expect(topPadding(elements[0]), 12);
    expect(topPadding(elements[1]), 18);
    // header + one divider between the two R rows; none before a header.
    expect(find.byType(Divider), findsNWidgets(2));
  });

  group('station roundel', () {
    Future<void> pumpStation(WidgetTester tester, String id) async {
      await pumpWithMetroProviders(
        tester,
        MetroStationDetailView(
          system: 'TRTC',
          stationId: id,
          name: '站',
          repository: _Quiet(),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 6));
    }

    Finder roundels() => find.byWidgetPredicate(
      (w) => w.runtimeType.toString() == '_MetroRoundel',
    );

    Text textIn(WidgetTester tester, String data) => tester.widget<Text>(
      find.descendant(of: roundels(), matching: find.text(data)),
    );

    testWidgets('splits the code into line letters over the number', (
      tester,
    ) async {
      await pumpStation(tester, 'BR14');
      final box = tester.widget<Container>(
        find.descendant(of: roundels(), matching: find.byType(Container)).first,
      );
      final decoration = box.decoration! as BoxDecoration;
      expect(decoration.color, AppTheme.mrtBR);
      expect(decoration.borderRadius, BorderRadius.circular(8));
      expect(tester.getSize(roundels()), const Size(30, 30));

      final letters = textIn(tester, 'BR');
      expect(letters.style!.fontSize, 10);
      expect(letters.style!.height, 1);
      expect(letters.style!.fontWeight, FontWeight.w700);
      expect(letters.style!.color, Colors.white);
      expect(letters.textScaler, TextScaler.noScaling);

      final number = textIn(tester, '14');
      expect(number.style!.fontSize, 9);
      expect(number.style!.height, 1.2);
      expect(number.style!.fontWeight, FontWeight.w700);
      expect(number.style!.color, Colors.white);
      expect(number.textScaler, TextScaler.noScaling);
    });

    testWidgets('a light line colour switches the text to ink', (
      tester,
    ) async {
      await pumpStation(tester, 'Y07');
      expect(textIn(tester, 'Y').style!.color, const Color(0xFF111111));
      expect(textIn(tester, '07').style!.color, const Color(0xFF111111));
    });

    testWidgets('lowercase codes and branch suffixes still split', (
      tester,
    ) async {
      await pumpStation(tester, 'g03A');
      expect(textIn(tester, 'g'), isNotNull);
      expect(textIn(tester, '03A'), isNotNull);
    });

    testWidgets('a code without a number shows only its letters', (
      tester,
    ) async {
      await pumpStation(tester, 'BL');
      expect(
        find.descendant(of: roundels(), matching: find.byType(Text)),
        findsOneWidget,
      );
    });
  });
}
