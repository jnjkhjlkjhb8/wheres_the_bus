import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart';
import 'package:wheres_the_bus/data/models/feedback_models.dart';
import 'package:wheres_the_bus/data/repositories/feedback_repository.dart';
import 'package:wheres_the_bus/features/feedback/bloc/feedback_bloc.dart';
import 'package:wheres_the_bus/features/feedback/bloc/feedback_event.dart';
import 'package:wheres_the_bus/features/feedback/view/feedback_screen.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/motion/pressable.dart';

class _FakeRepo implements FeedbackRepository {
  _FakeRepo({this.gate});

  /// When set, submit blocks on it, holding the page in its submitting state
  /// for as long as the test needs.
  final Completer<void>? gate;

  Exception? submitError;
  int submitCalls = 0;
  FeedbackCategory? sentCategory;

  @override
  Future<FeedbackDiagnostics> collect({
    required String screen,
    required String locale,
  }) async => FeedbackDiagnostics(
    appVersion: '1.4.2+312',
    platform: 'ios',
    osVersion: 'Version 18.2',
    screen: screen,
    locale: locale,
  );

  @override
  Future<FeedbackReceipt> submit({
    required FeedbackCategory category,
    required String body,
    required FeedbackDiagnostics diagnostics,
  }) async {
    submitCalls++;
    sentCategory = category;
    if (gate != null) await gate!.future;
    if (submitError != null) throw submitError!;
    return FeedbackReceipt(
      threadId: 'a1b2c3d4-0000-4000-8000-000000000000',
      createdAt: DateTime.utc(2026, 7, 27),
    );
  }
}

/// Whether the submit control is currently tappable. The button is a
/// [Pressable] whose enabled flag is the only thing standing between a
/// half-written report and the server.
bool _submitEnabled(WidgetTester tester) {
  final pressable = tester.widget<Pressable>(
    find.ancestor(
      of: find.text('送出'),
      matching: find.byType(Pressable),
    ),
  );
  return pressable.enabled && pressable.onTap != null;
}

Future<void> _pumpPage(
  WidgetTester tester,
  _FakeRepo repo, {
  String? subject,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppI18n.localizationsDelegates,
      supportedLocales: AppI18n.supportedLocales,
      home: BlocProvider(
        create: (_) =>
            FeedbackBloc(repository: repo)
              ..add(const FeedbackOpened(screen: '/settings', locale: 'zh-TW')),
        child: FeedbackView(subject: subject),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  // The draft is process-wide on purpose; one test's typing must not leak
  // into the next one's empty page.
  setUp(FeedbackDraft.clear);

  testWidgets('an empty report cannot be sent', (tester) async {
    await _pumpPage(tester, _FakeRepo());

    expect(_submitEnabled(tester), isFalse);
    expect(find.text('回報問題'), findsOneWidget);
  });

  testWidgets('a disabled send says why, and the reason goes once typed', (
    tester,
  ) async {
    await _pumpPage(tester, _FakeRepo());
    expect(find.text('先寫下狀況說明才能送出'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '顯示 2 分，等了 10 分');
    await tester.pump();

    expect(find.text('先寫下狀況說明才能送出'), findsNothing);
    expect(_submitEnabled(tester), isTrue);
  });

  testWidgets('a disabled send waits on the device read, and says so', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppI18n.localizationsDelegates,
        supportedLocales: AppI18n.supportedLocales,
        // No FeedbackOpened: the diagnostics never arrive.
        home: BlocProvider(
          create: (_) => FeedbackBloc(repository: _FakeRepo()),
          child: const FeedbackView(),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), '有內容');
    await tester.pump();

    expect(_submitEnabled(tester), isFalse);
    // The disclosure says it too; the line by the button is the second one.
    expect(find.text('正在讀取裝置資訊…'), findsNWidgets(2));
  });

  testWidgets('leaving keeps the draft, and the next visit picks it up', (
    tester,
  ) async {
    await _pumpPage(tester, _FakeRepo());
    await tester.tap(find.text('到站時間'));
    await tester.enterText(find.byType(TextField), '寫到一半');
    await tester.pump();

    await tester.pumpWidget(const SizedBox.shrink());
    await _pumpPage(tester, _FakeRepo());

    expect(find.text('寫到一半'), findsOneWidget);
    expect(FeedbackDraft.category, FeedbackCategory.eta);
    expect(_submitEnabled(tester), isTrue);
  });

  testWidgets('the page it came from is named, and 不是這個 drops it', (
    tester,
  ) async {
    await _pumpPage(tester, _FakeRepo(), subject: '307 · 往 板橋');
    expect(find.text('你在回報'), findsOneWidget);
    expect(find.text('307 · 往 板橋'), findsOneWidget);
    expect(find.textContaining('/settings'), findsOneWidget);

    await tester.tap(find.text('不是這個'));
    await tester.pumpAndSettle();

    expect(find.text('307 · 往 板橋'), findsNothing);
    // The page location goes with it, so the report no longer points there.
    expect(find.textContaining('/settings'), findsNothing);
  });

  testWidgets('no subject, no card', (tester) async {
    await _pumpPage(tester, _FakeRepo(), subject: '');
    expect(find.text('你在回報'), findsNothing);
  });

  testWidgets('a stored report clears the draft', (tester) async {
    await _pumpPage(tester, _FakeRepo());
    await tester.enterText(find.byType(TextField), '送出去');
    await tester.pump();
    await tester.tap(find.text('送出'));
    await tester.pumpAndSettle();

    expect(FeedbackDraft.body, isEmpty);
    expect(FeedbackDraft.category, FeedbackCategory.routeData);
  });

  testWidgets('whitespace alone is not a report', (tester) async {
    await _pumpPage(tester, _FakeRepo());

    await tester.enterText(find.byType(TextField), '   \n  ');
    await tester.pump();

    expect(_submitEnabled(tester), isFalse);
  });

  testWidgets('the counter appears near the ceiling and marks the limit', (
    tester,
  ) async {
    await _pumpPage(tester, _FakeRepo());
    await tester.enterText(
      find.byType(TextField),
      'a' * (feedbackBodyLimit - 199),
    );
    await tester.pump();
    expect(find.text('199 / 200'), findsOneWidget);
    expect(_submitEnabled(tester), true);
    await tester.enterText(find.byType(TextField), 'a' * feedbackBodyLimit);
    await tester.pump();
    final counter = tester.widget<Text>(find.text('0 / 200'));
    expect(
      counter.style!.color,
      Theme.of(tester.element(find.text('0 / 200'))).colorScheme.error,
    );
    expect(_submitEnabled(tester), true);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the disclosure names what will be attached', (tester) async {
    await _pumpPage(tester, _FakeRepo());

    expect(find.textContaining('會一併送出'), findsOneWidget);
    expect(
      find.text('1.4.2+312 · ios · Version 18.2 · zh-TW · /settings'),
      findsOneWidget,
    );
    expect(find.textContaining('不含位置'), findsOneWidget);
  });

  testWidgets('typing arms the control and sends the chosen category', (
    tester,
  ) async {
    final repo = _FakeRepo();
    await _pumpPage(tester, repo);

    await tester.enterText(find.byType(TextField), '310 的到站時間一直跳');
    await tester.pump();
    expect(_submitEnabled(tester), isTrue);

    await tester.tap(find.text('到站時間'));
    await tester.pump();
    await tester.tap(find.text('送出'));
    await tester.pumpAndSettle();

    expect(repo.submitCalls, 1);
    expect(repo.sentCategory, FeedbackCategory.eta);
  });

  testWidgets('the control is disabled for the whole in-flight window', (
    tester,
  ) async {
    final gate = Completer<void>();
    final repo = _FakeRepo(gate: gate);
    await _pumpPage(tester, repo);

    await tester.enterText(find.byType(TextField), '一直閃退');
    await tester.pump();
    await tester.tap(find.text('送出'));
    await tester.pump();

    // Mid-flight: the label is replaced by the spinner, so there is nothing
    // left to tap a second time.
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('送出'), findsNothing);

    gate.complete();
    await tester.pumpAndSettle();
    expect(repo.submitCalls, 1);
  });

  testWidgets('a stored report shows its case number', (tester) async {
    await _pumpPage(tester, _FakeRepo());

    await tester.enterText(find.byType(TextField), '站名錯了');
    await tester.pump();
    await tester.tap(find.text('送出'));
    await tester.pumpAndSettle();

    expect(find.text('已送出'), findsOneWidget);
    expect(find.text('A1B2C3D4'), findsOneWidget);
    // The release has no in-app reply, and the panel says so rather than
    // leaving the rider waiting for one.
    expect(find.textContaining('不會收到個別回信'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('a rejected report keeps what was typed and explains why', (
    tester,
  ) async {
    final repo = _FakeRepo()..submitError = const GrpcError.resourceExhausted();
    await _pumpPage(tester, repo);

    await tester.enterText(find.byType(TextField), '希望可以加入公車動態');
    await tester.pump();
    await tester.tap(find.text('送出'));
    await tester.pumpAndSettle();

    expect(find.textContaining('上限'), findsOneWidget);
    expect(find.text('希望可以加入公車動態'), findsOneWidget);
    expect(_submitEnabled(tester), isTrue);
  });
}
