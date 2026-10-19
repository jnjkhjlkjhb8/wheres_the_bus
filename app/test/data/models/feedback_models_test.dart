import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/models/feedback_models.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/l10n/app_i18n_en.dart';
import 'package:wheres_the_bus/l10n/app_i18n_zh.dart';

class _CategoryStrings extends AppI18nEn {
  @override
  String get feedbackCatRouteData => 'Route issue';
  @override
  String get feedbackCatRouteDataHint => 'Identify the route';
  @override
  String get feedbackCatEta => 'Arrival issue';
  @override
  String get feedbackCatEtaHint => 'Describe the arrival prediction';
  @override
  String get feedbackCatCrash => 'App failure';
  @override
  String get feedbackCatCrashHint => 'Describe the failed action';
  @override
  String get feedbackCatSuggestion => 'Suggestion';
  @override
  String get feedbackCatSuggestionHint => 'Describe the proposed improvement';
}

void main() {
  test(
    'report categories keep their wire values independent of localization',
    () {
      const wire = {
        FeedbackCategory.routeData: 'route_data',
        FeedbackCategory.eta: 'eta',
        FeedbackCategory.crash: 'crash',
        FeedbackCategory.suggestion: 'suggestion',
      };
      for (final entry in wire.entries) {
        expect(entry.key.wire, entry.value);
      }
      for (final strings in <AppI18n>[
        AppI18nEn(),
        AppI18nZh(),
        _CategoryStrings(),
      ]) {
        expect(
          FeedbackCategory.routeData.labelOf(strings),
          strings.feedbackCatRouteData,
        );
        expect(
          FeedbackCategory.routeData.hintOf(strings),
          strings.feedbackCatRouteDataHint,
        );
        expect(
          FeedbackCategory.eta.labelOf(strings),
          strings.feedbackCatEta,
        );
        expect(
          FeedbackCategory.eta.hintOf(strings),
          strings.feedbackCatEtaHint,
        );
        expect(
          FeedbackCategory.crash.labelOf(strings),
          strings.feedbackCatCrash,
        );
        expect(
          FeedbackCategory.crash.hintOf(strings),
          strings.feedbackCatCrashHint,
        );
        expect(
          FeedbackCategory.suggestion.labelOf(strings),
          strings.feedbackCatSuggestion,
        );
        expect(
          FeedbackCategory.suggestion.hintOf(strings),
          strings.feedbackCatSuggestionHint,
        );
      }
    },
  );

  test(
    'diagnostic disclosure omits unavailable values '
    'and keeps its reading order',
    () {
      const empty = FeedbackDiagnostics();
      const complete = FeedbackDiagnostics(
        appVersion: '2.7.1+8',
        platform: 'android',
        osVersion: '16',
        screen: '/bus/route/:subRouteUid',
        locale: 'zh-Hant-TW',
      );
      const partial = FeedbackDiagnostics(platform: 'ios', screen: '/settings');
      const appOnly = FeedbackDiagnostics(appVersion: '2.7.1');
      const osOnly = FeedbackDiagnostics(osVersion: '18');
      const localeOnly = FeedbackDiagnostics(locale: 'en');
      expect(empty.summary, isEmpty);
      expect(complete.summary, [
        '2.7.1+8',
        'android',
        '16',
        'zh-Hant-TW',
        '/bus/route/:subRouteUid',
      ]);
      expect(partial.summary, ['ios', '/settings']);
      expect(appOnly.summary, ['2.7.1']);
      expect(osOnly.summary, ['18']);
      expect(localeOnly.summary, ['en']);
    },
  );

  test('diagnostic values distinguish every attached field', () {
    FeedbackDiagnostics value(List<String> fields) => FeedbackDiagnostics(
      appVersion: fields[0],
      platform: fields[1],
      osVersion: fields[2],
      screen: fields[3],
      locale: fields[4],
    );
    const fields = ['2.7.1', 'ios', '18', '/settings', 'en'];
    final original = value(fields);
    final equal = value(List.of(fields));
    expect(identical(original, equal), isFalse);
    expect(equal, original);
    expect(equal.hashCode, original.hashCode);
    for (var index = 0; index < fields.length; index++) {
      final different = List.of(fields);
      different[index] = '${fields[index]}-changed';
      final changed = value(different);
      expect(changed, isNot(original));
      expect({original, equal, changed}, hasLength(2));
    }
  });

  test('report references quote the first case segment in uppercase', () {
    final createdAt = DateTime.utc(2026, 10, 11, 8, 30);
    for (final entry in {
      'a1b2c3d4-0000-4000-8000-000000000000': 'A1B2C3D4',
      'ab09': 'AB09',
      'a-b-c': 'A',
    }.entries) {
      expect(
        FeedbackReceipt(threadId: entry.key, createdAt: createdAt).reference,
        entry.value,
      );
    }
  });

  test('receipt value identity includes both the thread and creation time', () {
    FeedbackReceipt value(String id, DateTime createdAt) =>
        FeedbackReceipt(threadId: id, createdAt: createdAt);
    final createdAt = DateTime.utc(2026, 10, 11, 8, 30);
    final original = value('ab09-thread', createdAt);
    final equal = value('ab09-thread', DateTime.utc(2026, 10, 11, 8, 30));
    final otherThread = value('cd10-thread', createdAt);
    final otherTime = value(
      'ab09-thread',
      createdAt.add(const Duration(seconds: 1)),
    );
    expect(identical(original, equal), isFalse);
    expect(equal, original);
    expect(equal.hashCode, original.hashCode);
    expect(otherThread, isNot(original));
    expect(otherTime, isNot(original));
    expect({original, equal, otherThread, otherTime}, hasLength(3));
  });
}
