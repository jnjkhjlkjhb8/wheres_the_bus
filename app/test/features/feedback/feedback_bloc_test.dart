import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart';
import 'package:wheres_the_bus/data/models/feedback_models.dart';
import 'package:wheres_the_bus/data/repositories/feedback_repository.dart';
import 'package:wheres_the_bus/features/feedback/bloc/feedback_bloc.dart';
import 'package:wheres_the_bus/features/feedback/bloc/feedback_event.dart';
import 'package:wheres_the_bus/features/feedback/bloc/feedback_state.dart';

import '../../support/helpers/i18n.dart';

class _FakeRepo implements FeedbackRepository {
  FeedbackDiagnostics collected = const FeedbackDiagnostics(
    appVersion: '1.4.2+312',
    platform: 'ios',
  );
  Exception? submitError;
  FeedbackReceipt? submitResult;

  String? collectedScreen;
  String? collectedLocale;
  FeedbackCategory? sentCategory;
  String? sentBody;
  FeedbackDiagnostics? sentDiagnostics;
  int submitCalls = 0;

  @override
  Future<FeedbackDiagnostics> collect({
    required String screen,
    required String locale,
  }) async {
    collectedScreen = screen;
    collectedLocale = locale;
    return collected;
  }

  @override
  Future<FeedbackReceipt> submit({
    required FeedbackCategory category,
    required String body,
    required FeedbackDiagnostics diagnostics,
  }) async {
    submitCalls++;
    sentCategory = category;
    sentBody = body;
    sentDiagnostics = diagnostics;
    if (submitError != null) throw submitError!;
    return submitResult!;
  }
}

FeedbackReceipt _receipt() => FeedbackReceipt(
  threadId: 'a1b2c3d4-0000-4000-8000-000000000000',
  createdAt: DateTime.utc(2026, 7, 27),
);

void main() {
  test('opening collects the diagnostics the sheet will disclose', () async {
    final repo = _FakeRepo();
    final bloc = FeedbackBloc(repository: repo);
    addTearDown(bloc.close);

    bloc.add(const FeedbackOpened(screen: '/settings', locale: 'zh-Hant-TW'));
    await bloc.stream.firstWhere((s) => s.diagnostics != null);

    expect(repo.collectedScreen, '/settings');
    expect(repo.collectedLocale, 'zh-Hant-TW');
    expect(bloc.state.diagnostics?.appVersion, '1.4.2+312');
    expect(bloc.state.status, FeedbackStatus.composing);
  });

  test('a stored report becomes the receipt state', () async {
    final repo = _FakeRepo()..submitResult = _receipt();
    final bloc = FeedbackBloc(repository: repo);
    addTearDown(bloc.close);

    bloc.add(const FeedbackOpened(screen: '/settings', locale: 'zh-TW'));
    await bloc.stream.firstWhere((s) => s.diagnostics != null);
    bloc.add(
      const FeedbackSubmitted(category: FeedbackCategory.eta, body: '時間不準'),
    );
    await bloc.stream.firstWhere((s) => s.status == FeedbackStatus.sent);

    expect(repo.sentCategory, FeedbackCategory.eta);
    expect(repo.sentBody, '時間不準');
    // The diagnostics collected on open are the ones sent, not a fresh read at
    // submit time — what the rider was shown is what leaves the device.
    expect(repo.sentDiagnostics, repo.collected);
    expect(bloc.state.receipt?.reference, 'A1B2C3D4');
  });

  test('a failed submission returns to composing with a reason', () async {
    final repo = _FakeRepo()
      ..submitError = const GrpcError.resourceExhausted(
        'at most 10 reports per day',
      );
    final bloc = FeedbackBloc(repository: repo);
    addTearDown(bloc.close);

    bloc.add(
      const FeedbackSubmitted(
        category: FeedbackCategory.crash,
        body: '一直閃退',
      ),
    );
    await bloc.stream.firstWhere((s) => s.error != null);

    expect(bloc.state.status, FeedbackStatus.composing);
    expect(bloc.state.error?.messageOf(zhStrings), contains('上限'));
    expect(bloc.state.receipt, isNull);
  });

  test('resubmitting clears the previous error before it starts', () async {
    final repo = _FakeRepo()..submitError = const GrpcError.unavailable();
    final bloc = FeedbackBloc(repository: repo);
    addTearDown(bloc.close);

    bloc.add(
      const FeedbackSubmitted(category: FeedbackCategory.suggestion, body: 'a'),
    );
    await bloc.stream.firstWhere((s) => s.error != null);

    repo
      ..submitError = null
      ..submitResult = _receipt();
    final states = <FeedbackState>[];
    final subscription = bloc.stream.listen(states.add);
    bloc.add(
      const FeedbackSubmitted(category: FeedbackCategory.suggestion, body: 'a'),
    );
    await bloc.stream.firstWhere((s) => s.status == FeedbackStatus.sent);
    await subscription.cancel();

    expect(states.first.status, FeedbackStatus.submitting);
    expect(states.first.error, isNull);
    expect(bloc.state.error, isNull);
  });

  test('每種伺服器拒絕都有自己的下一步', () {
    // Asserts on the rendered zh-TW copy, not on the case, so a rejection that
    // silently starts pointing at the wrong next step still fails here.
    String message(Object error) =>
        describeSubmitFailure(error).messageOf(zhStrings);

    expect(message(const GrpcError.resourceExhausted()), contains('明天'));
    expect(message(const GrpcError.permissionDenied()), contains('重新開啟'));
    expect(message(const GrpcError.invalidArgument()), contains('換個'));
    // Anything else falls through to the app-wide error vocabulary rather than
    // inventing new wording for being offline.
    expect(message(const GrpcError.unavailable()), contains('離線'));
  });
}
