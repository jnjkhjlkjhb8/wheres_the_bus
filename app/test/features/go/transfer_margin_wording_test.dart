import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/data/models/plan_models.dart';
import 'package:wheres_the_bus/features/go/widgets/route_option_card.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/l10n/app_i18n_zh.dart';

PlanTransfer _transfer(
  TransferReliability reliability, {
  bool estimated = false,
  int seconds = 400,
}) => PlanTransfer(
  fromLeg: 1,
  toLeg: 3,
  marginSeconds: seconds,
  reliability: reliability,
  timesEstimated: estimated,
);

const TransferReliability _comfortable = TransferReliability.comfortable;
const TransferReliability _tight = TransferReliability.tight;
const TransferReliability _unspecified = TransferReliability.unknown;

PlanRoute _route({
  List<PlanTransfer> transfers = const [],
  int fare = 0,
  bool fareComplete = true,
}) => PlanRoute(
  travelTime: 600,
  startTime: '2026-07-11T08:00:00',
  endTime: '2026-07-11T08:10:00',
  transfers: transfers.length,
  totalFare: fare,
  fareComplete: fareComplete,
  sections: const [],
  transferMargins: transfers,
);

Widget _card(PlanRoute route, {Brightness brightness = Brightness.light}) =>
    MaterialApp(
      theme: brightness == Brightness.light ? AppTheme.light : AppTheme.dark,
      locale: const Locale('zh'),
      localizationsDelegates: AppI18n.localizationsDelegates,
      supportedLocales: AppI18n.supportedLocales,
      home: Scaffold(
        body: RouteOptionCard(route: route, highlighted: false, onTap: () {}),
      ),
    );

void main() {
  final i18n = AppI18nZh();

  group('transferMarginWords', () {
    test('a measured comfortable transfer says how long and 充裕', () {
      expect(
        transferMarginWords(i18n, _transfer(_comfortable)),
        '有 6 分鐘 · 充裕',
      );
    });

    test('a tight transfer says 容易接不上', () {
      expect(
        transferMarginWords(i18n, _transfer(_tight, seconds: 130)),
        '只有 2 分鐘 · 容易接不上',
      );
    });

    test('an estimated comfortable transfer keeps 充裕, noted as a guess', () {
      expect(
        transferMarginWords(i18n, _transfer(_comfortable, estimated: true)),
        '約 6 分鐘 · 充裕 · 時間為估計',
      );
    });

    test('an estimated tight transfer still warns, and says it is a guess', () {
      expect(
        transferMarginWords(i18n, _transfer(_tight, estimated: true)),
        '約 6 分鐘 · 容易接不上 · 時間為估計',
      );
    });

    test('a transfer the planner could not time gets no words', () {
      expect(transferMarginWords(i18n, _transfer(_unspecified)), isNull);
      expect(
        transferMarginWords(i18n, _transfer(_unspecified, estimated: true)),
        isNull,
      );
    });

    test('a broken connection reads as no room, never a negative', () {
      expect(
        transferMarginWords(i18n, _transfer(_tight, seconds: -200)),
        '只有 0 分鐘 · 容易接不上',
      );
    });
  });

  group('transferMarginColor', () {
    final light = AppTheme.light.colorScheme;
    final dark = AppTheme.dark.colorScheme;

    test('tight is the warning text colour on either surface', () {
      expect(
        transferMarginColor(_transfer(_tight), light),
        AppTheme.etaApproaching,
      );
      expect(
        transferMarginColor(_transfer(_tight), dark),
        AppTheme.statusApproach,
      );
      expect(
        transferMarginColor(_transfer(_tight, estimated: true), light),
        AppTheme.etaApproaching,
      );
    });

    test('measured comfortable is the positive text colour', () {
      expect(
        transferMarginColor(_transfer(_comfortable), light),
        AppTheme.statusArrivingText,
      );
      expect(
        transferMarginColor(_transfer(_comfortable), dark),
        AppTheme.statusArriving,
      );
    });

    test('estimated comfortable is plain secondary text', () {
      expect(
        transferMarginColor(_transfer(_comfortable, estimated: true), light),
        light.onSurfaceVariant,
      );
    });
  });

  group('result card', () {
    testWidgets('names the transfer most likely to be missed', (tester) async {
      await tester.pumpWidget(
        _card(
          _route(
            transfers: [
              _transfer(_comfortable),
              _transfer(_tight, seconds: 130),
            ],
          ),
        ),
      );

      final line = tester.widget<Text>(find.text('轉乘只有 2 分鐘 · 容易接不上'));
      expect(line.style?.color, AppTheme.etaApproaching);
      expect(line.style?.fontWeight, FontWeight.w600);
      expect(find.textContaining('充裕'), findsNothing);
    });

    testWidgets('a comfortable line is not bold', (tester) async {
      await tester.pumpWidget(
        _card(_route(transfers: [_transfer(_comfortable)])),
      );

      final line = tester.widget<Text>(find.text('轉乘有 6 分鐘 · 充裕'));
      expect(line.style?.fontWeight, isNot(FontWeight.w600));
      expect(line.style?.color, AppTheme.statusArrivingText);
    });

    testWidgets('says nothing about a transfer it cannot time', (tester) async {
      await tester.pumpWidget(
        _card(_route(transfers: [_transfer(_unspecified)])),
      );

      expect(find.textContaining('分鐘 ·'), findsNothing);
    });

    testWidgets('shows a fare only when every leg was priced', (tester) async {
      await tester.pumpWidget(_card(_route(fare: 35)));
      expect(find.text('35'), findsOneWidget);

      await tester.pumpWidget(_card(_route(fare: 35, fareComplete: false)));
      expect(find.text('35'), findsNothing);

      await tester.pumpWidget(_card(_route()));
      expect(find.text(r'NT$'), findsNothing);
    });
  });
}
