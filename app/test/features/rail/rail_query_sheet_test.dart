import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/features/rail/bloc/rail_event.dart';
import 'package:wheres_the_bus/features/rail/widgets/rail_query_sheet.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/motion/pressable.dart';
import 'package:wheres_the_bus/shared/widgets/app_button.dart';
import 'package:wheres_the_bus/shared/widgets/app_date_picker.dart';
import 'package:wheres_the_bus/shared/widgets/app_sliding_segment.dart';

void main() {
  late Box<dynamic> recents;
  final submissions = <RailQuerySubmission>[];
  final systems = <RailSystem>[];
  var backs = 0;
  setUp(() async {
    recents = await Hive.openBox<dynamic>(
      'recent_searches',
      bytes: Uint8List(0),
    );
    submissions.clear();
    systems.clear();
    backs = 0;
  });
  tearDown(() async => recents.close());

  Future<void> show(
    WidgetTester tester, {
    RailQueryPreset? preset,
    bool reduced = false,
  }) async {
    tester.view.physicalSize = const Size(430, 1300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        locale: const Locale('zh'),
        localizationsDelegates: AppI18n.localizationsDelegates,
        supportedLocales: AppI18n.supportedLocales,
        home: MediaQuery(
          data: MediaQueryData(
            size: const Size(430, 1300),
            disableAnimations: reduced,
          ),
          child: Scaffold(
            body: RailQuerySheetContent(
              preset: preset,
              onSubmit: submissions.add,
              onSystemChanged: systems.add,
              onBack: () => backs++,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Pressable button(WidgetTester tester, Finder content) =>
      tester.widget<Pressable>(
        find.ancestor(of: content, matching: find.byType(Pressable)).first,
      );
  void query(WidgetTester tester) => tester
      .widget<Pressable>(
        find.byWidgetPredicate(
          (w) => w is Pressable && w.semanticLabel == '查詢',
        ),
      )
      .onTap!();
  Future<void> dispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  }

  testWidgets(
    'preset ids and time survive submission and swapped resubmission',
    (tester) async {
      await show(
        tester,
        preset: RailQueryPreset(
          system: RailSystem.tra,
          originName: '台北',
          originId: '1000',
          destName: '台中',
          destId: '3300',
          date: DateTime(2030, 1, 2, 9, 10),
          isDeparture: false,
        ),
      );
      final mode = tester.widget<AppSlidingSegment<bool>>(
        find.byType(AppSlidingSegment<bool>),
      );
      expect(mode.value, isFalse);
      query(tester);
      final first = submissions.single as RailOdQuerySubmission;
      expect(
        (
          first.originId,
          first.destId,
          first.date.hour,
          first.date.minute,
          first.isDeparture,
        ),
        ('1000', '3300', 9, 10, false),
      );
      final swap = button(tester, find.byIcon(Icons.swap_horiz_rounded));
      expect(swap.semanticLabel, '對調起訖點');
      swap.onTap!();
      await tester.pumpAndSettle();
      final swapped = submissions.last as RailOdQuerySubmission;
      expect(
        (
          swapped.originName,
          swapped.originId,
          swapped.destName,
          swapped.destId,
        ),
        ('台中', '3300', '台北', '1000'),
      );
      mode.onChanged(true);
      await tester.pumpAndSettle();
      query(tester);
      expect((submissions.last as RailOdQuerySubmission).isDeparture, isTrue);
      await dispose(tester);
    },
  );

  testWidgets('date and time pickers accept changes and retain cancellation', (
    tester,
  ) async {
    final today = DateTime.now();
    await show(
      tester,
      preset: RailQueryPreset(
        system: RailSystem.tra,
        originName: '台北',
        destName: '台中',
        date: today,
      ),
    );
    button(tester, find.text('日期')).onTap!();
    await tester.pumpAndSettle();
    final date = DateTime(today.year, today.month, 2);
    final picker = tester.widget<AppDatePicker>(find.byType(AppDatePicker));
    picker.onDaySelected(date);
    await tester.pumpAndSettle();
    button(tester, find.text('時間')).onTap!();
    await tester.pumpAndSettle();
    tester
        .widget<CupertinoDatePicker>(find.byType(CupertinoDatePicker))
        .onDateTimeChanged(DateTime(today.year, today.month, 2, 14, 35));
    tester.widget<AppButton>(find.widgetWithText(AppButton, '完成')).onPressed!();
    await tester.pumpAndSettle();
    query(tester);
    expect(
      (submissions.last as RailOdQuerySubmission).date,
      DateTime(today.year, today.month, 2, 14, 35),
    );
    button(tester, find.text('時間')).onTap!();
    await tester.pumpAndSettle();
    tester.widget<AppButton>(find.widgetWithText(AppButton, '取消')).onPressed!();
    await tester.pumpAndSettle();
    query(tester);
    expect((submissions.last as RailOdQuerySubmission).date.hour, 14);
    await dispose(tester);
  });

  testWidgets(
    'system changes restore saved OD while same segments do nothing',
    (tester) async {
      await recents.put('od_queries', [
        {
          'system': 'thsr',
          'originName': '台北',
          'originId': '01',
          'destName': '左營',
          'destId': '12',
        },
      ]);
      await show(tester, reduced: true);
      final system = tester.widget<AppSlidingSegment<RailSystem>>(
        find.byType(AppSlidingSegment<RailSystem>),
      );
      system.onChanged(RailSystem.tra);
      expect(systems, isEmpty);
      system.onChanged(RailSystem.thsr);
      await tester.pumpAndSettle();
      expect(systems.single, RailSystem.thsr);
      query(tester);
      expect((submissions.single as RailOdQuerySubmission).destName, '左營');
      final back = tester.widget<Pressable>(
        find.byWidgetPredicate(
          (w) => w is Pressable && w.semanticLabel == '返回',
        ),
      );
      back.onTap!();
      expect(backs, 1);
      await dispose(tester);
    },
  );

  testWidgets(
    'station picks replace ids while cancelling keeps the old choice',
    (tester) async {
      await show(
        tester,
        preset: const RailQueryPreset(
          system: RailSystem.thsr,
          originName: '台北',
          originId: '01',
          destName: '左營',
          destId: '12',
        ),
      );
      button(tester, find.text('台北')).onTap!();
      await tester.pumpAndSettle();
      Navigator.of(tester.element(find.byType(Dialog))).pop('板橋');
      await tester.pumpAndSettle();
      button(tester, find.text('左營')).onTap!();
      await tester.pumpAndSettle();
      Navigator.of(tester.element(find.byType(Dialog))).pop();
      await tester.pumpAndSettle();
      query(tester);
      final request = submissions.last as RailOdQuerySubmission;
      expect(
        (request.originName, request.originId, request.destId),
        ('板橋', null, '12'),
      );
      button(tester, find.text('左營')).onTap!();
      await tester.pumpAndSettle();
      Navigator.of(tester.element(find.byType(Dialog))).pop('台中');
      await tester.pumpAndSettle();
      query(tester);
      expect((submissions.last as RailOdQuerySubmission).destId, isNull);
      tester
          .widget<AppSlidingSegment<RailSystem>>(
            find.byType(AppSlidingSegment<RailSystem>),
          )
          .onChanged(RailSystem.tra);
      await tester.pumpAndSettle();
      button(tester, find.text('起點站')).onTap!();
      await tester.pumpAndSettle();
      Navigator.of(tester.element(find.byType(Dialog))).pop('台北');
      await tester.pumpAndSettle();
      button(tester, find.text('終點站')).onTap!();
      await tester.pumpAndSettle();
      Navigator.of(tester.element(find.byType(Dialog))).pop('台中');
      await tester.pumpAndSettle();
      query(tester);
      expect(
        (submissions.last as RailOdQuerySubmission).system,
        RailSystem.tra,
      );
      await dispose(tester);
    },
  );

  testWidgets('train query input and recents keep their own systems', (
    tester,
  ) async {
    await recents.put('train_queries', [
      {'system': 'thsr', 'trainNo': '601'},
      {'system': 'tra', 'trainNo': '123'},
    ]);
    await show(tester);
    final mode = tester.widget<AppSlidingSegment<RailQueryMode>>(
      find.byType(AppSlidingSegment<RailQueryMode>),
    );
    mode.onChanged(RailQueryMode.od);
    mode.onChanged(RailQueryMode.train);
    await tester.pumpAndSettle();
    button(tester, find.text('601')).onTap!();
    await tester.pumpAndSettle();
    expect(systems.single, RailSystem.thsr);
    query(tester);
    expect((submissions.last as RailTrainQuerySubmission).trainNo, '601');
    expect(
      (submissions.last as RailTrainQuerySubmission).system,
      RailSystem.thsr,
    );
    await tester.enterText(find.byType(TextField), 'abc27');
    await tester.pumpAndSettle();
    query(tester);
    expect((submissions.last as RailTrainQuerySubmission).trainNo, '27');
    await dispose(tester);
  });

  testWidgets('the date row reads month/day with the weekday', (tester) async {
    await show(
      tester,
      preset: RailQueryPreset(
        system: RailSystem.tra,
        originName: '台北',
        destName: '台中',
        date: DateTime(2030, 1, 2, 9, 10),
      ),
    );

    expect(find.text('01/02 (三)'), findsOneWidget);
    await dispose(tester);
  });

  testWidgets('one station alone neither enables nor borrows the last query', (
    tester,
  ) async {
    await recents.put('od_queries', [
      {
        'system': 'tra',
        'originName': '高雄',
        'originId': '4400',
        'destName': '左營',
        'destId': '4340',
      },
    ]);
    Pressable submit() => tester.widget<Pressable>(
      find.byWidgetPredicate((w) => w is Pressable && w.semanticLabel == '查詢'),
    );

    await show(
      tester,
      preset: RailQueryPreset(
        system: RailSystem.tra,
        originName: '台北',
        originId: '1000',
        destName: '',
        destId: '',
        date: DateTime(2030, 1, 2, 9, 10),
      ),
    );
    expect(submit().onTap, isNull);
    expect(find.text('左營'), findsNothing);
    await dispose(tester);

    await show(
      tester,
      preset: RailQueryPreset(
        system: RailSystem.tra,
        originName: '',
        originId: '',
        destName: '台中',
        destId: '3300',
        date: DateTime(2030, 1, 2, 9, 10),
      ),
    );
    expect(submit().onTap, isNull);
    expect(find.text('高雄'), findsNothing);
    await dispose(tester);
  });
}
