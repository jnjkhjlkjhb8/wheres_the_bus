import 'package:equatable/equatable.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';

/// Rune ceiling on a report body, mirroring the server's own limit. Enforced in
/// the field so the rider is stopped while typing rather than rejected after
/// composing something long.
const feedbackBodyLimit = 2000;

/// What a rider is reporting. The wire values are constrained by both the
/// server and a CHECK on `feedback_thread`, so this list is the app's half of
/// a contract — renaming a case is fine, changing a [wire] value is not.
enum FeedbackCategory {
  routeData(wire: 'route_data'),
  eta(wire: 'eta'),
  crash(wire: 'crash'),
  suggestion(wire: 'suggestion');

  const FeedbackCategory({required this.wire});

  /// The rider-facing name on the category picker.
  String labelOf(AppI18n i18n) => switch (this) {
    FeedbackCategory.routeData => i18n.feedbackCatRouteData,
    FeedbackCategory.eta => i18n.feedbackCatEta,
    FeedbackCategory.crash => i18n.feedbackCatCrash,
    FeedbackCategory.suggestion => i18n.feedbackCatSuggestion,
  };

  /// What to ask for, once this category is chosen.
  String hintOf(AppI18n i18n) => switch (this) {
    FeedbackCategory.routeData => i18n.feedbackCatRouteDataHint,
    FeedbackCategory.eta => i18n.feedbackCatEtaHint,
    FeedbackCategory.crash => i18n.feedbackCatCrashHint,
    FeedbackCategory.suggestion => i18n.feedbackCatSuggestionHint,
  };

  /// The value sent to the server. Never localise this.
  final String wire;
}

/// Everything the app attaches to a report. Held as a value rather than read
/// at submit time so the sheet can show the rider exactly what will be sent
/// before they send it.
class FeedbackDiagnostics extends Equatable {
  const FeedbackDiagnostics({
    this.appVersion = '',
    this.platform = '',
    this.osVersion = '',
    this.screen = '',
    this.locale = '',
  });

  final String appVersion;
  final String platform;
  final String osVersion;

  /// The route pattern the rider was on, never a resolved path: the sheet
  /// records `/bus/route/:subRouteUid`, not which route they were looking at.
  final String screen;
  final String locale;

  /// The disclosure the sheet renders, in the order it reads best. Empty
  /// values drop out, so a field the device could not determine is absent
  /// rather than shown as a blank.
  List<String> get summary => [
    for (final value in [appVersion, platform, osVersion, locale, screen])
      if (value.isNotEmpty) value,
  ];

  @override
  List<Object?> get props => [appVersion, platform, osVersion, screen, locale];
}

/// The server's acknowledgement of a stored report.
class FeedbackReceipt extends Equatable {
  const FeedbackReceipt({required this.threadId, required this.createdAt});

  final String threadId;
  final DateTime createdAt;

  /// The case number shown to the rider: the first segment of the thread id.
  /// A quotable prefix, not a key — ops resolve it with a prefix match.
  String get reference => threadId.split('-').first.toUpperCase();

  @override
  List<Object?> get props => [threadId, createdAt];
}
