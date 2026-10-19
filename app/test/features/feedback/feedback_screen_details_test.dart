import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart';
import 'package:wheres_the_bus/data/models/feedback_models.dart';
import 'package:wheres_the_bus/data/repositories/feedback_repository.dart';
import 'package:wheres_the_bus/features/feedback/bloc/feedback_bloc.dart';
import 'package:wheres_the_bus/features/feedback/bloc/feedback_event.dart';
import 'package:wheres_the_bus/features/feedback/view/feedback_screen.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';

class _Repo implements FeedbackRepository {
  _Repo({this.gate, this.error});

  final Completer<void>? gate;
  final Exception? error;

  @override
  Future<FeedbackDiagnostics> collect({
    required String screen,
    required String locale,
  }) async => FeedbackDiagnostics(
    appVersion: '1.0.0',
    platform: 'ios',
    osVersion: '18',
    screen: screen,
    locale: locale,
  );

  @override
  Future<FeedbackReceipt> submit({
    required FeedbackCategory category,
    required String body,
    required FeedbackDiagnostics diagnostics,
  }) async {
    if (gate != null) await gate!.future;
    if (error != null) throw error!;
    return FeedbackReceipt(
      threadId: 'a1b2c3d4-0000-4000-8000-000000000000',
      createdAt: DateTime.utc(2026, 7, 27),
    );
  }
}

List<String> _recordPlatformCalls(WidgetTester tester) {
  final calls = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      calls.add(
        call.method == 'HapticFeedback.vibrate'
            ? '${call.arguments}'
            : call.method,
      );
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );
  return calls;
}

Future<void> _pump(WidgetTester tester, _Repo repo) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppI18n.localizationsDelegates,
      supportedLocales: AppI18n.supportedLocales,
      home: BlocProvider(
        create: (_) =>
            FeedbackBloc(repository: repo)
              ..add(const FeedbackOpened(screen: '/settings', locale: 'zh-TW')),
        child: const FeedbackView(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _submit(WidgetTester tester) async {
  await tester.enterText(find.byType(TextField), '站名錯了');
  await tester.pump();
  await tester.tap(find.text('送出'));
}

void main() {
  testWidgets('a rejected report does not buzz', (tester) async {
    final calls = _recordPlatformCalls(tester);
    await _pump(tester, _Repo(error: const GrpcError.resourceExhausted()));
    await _submit(tester);
    await tester.pumpAndSettle();
    expect(calls.where((c) => c.contains('Impact')), isEmpty);
  });

  testWidgets('a stored report buzzes once', (tester) async {
    final calls = _recordPlatformCalls(tester);
    await _pump(tester, _Repo());
    await _submit(tester);
    await tester.pumpAndSettle();
    expect(calls.where((c) => c.contains('Impact')), [
      'HapticFeedbackType.mediumImpact',
    ]);
  });

  testWidgets('sending drops the keyboard, shows a 2.5px spinner', (
    tester,
  ) async {
    final gate = Completer<void>();
    await _pump(tester, _Repo(gate: gate));
    await tester.tap(find.byType(TextField));
    await tester.pump();
    final editable = tester.widget<EditableText>(find.byType(EditableText));
    expect(editable.focusNode.hasFocus, isTrue);

    await _submit(tester);
    await tester.pump();
    expect(editable.focusNode.hasFocus, isFalse);
    expect(
      tester
          .widget<CircularProgressIndicator>(
            find.byType(CircularProgressIndicator),
          )
          .strokeWidth,
      2.5,
    );
    gate.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('the receipt slides up from 3% below as it arrives', (
    tester,
  ) async {
    final gate = Completer<void>();
    await _pump(tester, _Repo(gate: gate));
    await _submit(tester);
    await tester.pump();
    gate.complete();
    await tester.pump();
    await tester.pump();
    final slide = tester.widget<SlideTransition>(
      find
          .ancestor(
            of: find.text('已送出'),
            matching: find.byType(SlideTransition),
          )
          .first,
    );
    expect(slide.position.value.dx, 0);
    expect(slide.position.value.dy, closeTo(0.03, 0.03));
    expect(slide.position.value.dy, greaterThan(0));
    await tester.pumpAndSettle();
  });

  testWidgets('the counter is quiet while characters remain', (tester) async {
    await _pump(tester, _Repo());
    await tester.enterText(
      find.byType(TextField),
      'a' * (feedbackBodyLimit - 199),
    );
    await tester.pump();
    final text = tester.widget<Text>(find.text('199 / 200'));
    expect(
      text.style!.color,
      Theme.of(
        tester.element(find.text('199 / 200')),
      ).colorScheme.onSurfaceVariant,
    );
  });

  testWidgets('the submit button clears the gesture bar', (tester) async {
    tester.view
      ..devicePixelRatio = 1
      ..viewPadding = const FakeViewPadding(bottom: 34)
      ..padding = const FakeViewPadding(bottom: 34);
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewPadding);
    await _pump(tester, _Repo());
    final padded = find.byWidgetPredicate(
      (w) =>
          w is Padding &&
          w.padding == const EdgeInsets.fromLTRB(20, 12, 20, 54),
    );
    expect(padded, findsOneWidget);
  });

  testWidgets('the receipt panel clears the gesture bar and offers copy', (
    tester,
  ) async {
    tester.view
      ..devicePixelRatio = 1
      ..viewPadding = const FakeViewPadding(bottom: 34)
      ..padding = const FakeViewPadding(bottom: 34);
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewPadding);
    final calls = _recordPlatformCalls(tester);
    await _pump(tester, _Repo());
    await _submit(tester);
    await tester.pumpAndSettle();

    expect(
      find.byWidgetPredicate((w) => w is SizedBox && w.height == 42),
      findsOneWidget,
    );
    expect(find.text('複製編號'), findsOneWidget);
    expect(find.text('完成'), findsOneWidget);

    calls.clear();
    await tester.tap(find.text('複製編號'));
    await tester.pump();
    expect(calls, contains('Clipboard.setData'));
    expect(calls, contains('HapticFeedbackType.lightImpact'));
    await tester.pumpAndSettle(const Duration(seconds: 5));
  });
}
