import 'package:equatable/equatable.dart';
import 'package:wheres_the_bus/core/errors/app_error.dart';
import 'package:wheres_the_bus/data/models/alert_models.dart';

class AlertState extends Equatable {
  const AlertState({
    this.alertsBySource = const {},
    this.scope = const {},
    this.dismissedMessages = const {},
    this.readMessages = const {},
    this.sourceHealth = const {},
  });

  final Map<AlertSourceId, List<AlertViewModel>> alertsBySource;

  /// Every reported alert across all sources, unfiltered.
  List<AlertViewModel> get activeAlerts => [
    for (final alerts in alertsBySource.values) ...alerts,
  ];

  /// The rider's 訂閱範圍 (see `subscription_scope.dart`). An alert scoped to a
  /// route outside it is not shown; an alert that names no route is
  /// system-wide and is shown regardless.
  final Set<String> scope;

  final Set<String> dismissedMessages;
  final Set<String> readMessages;

  final Map<AlertSourceId?, AppError> sourceHealth;

  AppError? get error =>
      sourceHealth.values.isEmpty ? null : sourceHealth.values.first;

  List<AlertViewModel> get redAlerts =>
      visibleAlerts.where((a) => a.tone == NoticeTone.critical).toList();

  /// Inbox group 「進行中」: something is broken right now. A disruption the
  /// feed stops publishing has been resolved and leaves on its own.
  List<AlertViewModel> get ongoingNotices =>
      visibleAlerts.where((a) => a.ongoing).toList();

  /// Inbox group 「訊息」: route news and app announcements — things to read,
  /// never things happening.
  List<AlertViewModel> get messageNotices =>
      visibleAlerts.where((a) => !a.ongoing).toList();

  /// Alerts worth showing: in the rider's 訂閱範圍, not resolved, not
  /// dismissed.
  List<AlertViewModel> get visibleAlerts => activeAlerts
      .where(
        (a) =>
            a.level != AlertSeverity.green &&
            a.matchesScope(scope) &&
            !dismissedMessages.contains(a.message),
      )
      .toList();

  List<AlertViewModel> get contextualNotices => activeAlerts
      .where(
        (a) =>
            a.level != AlertSeverity.green &&
            !dismissedMessages.contains(a.message),
      )
      .toList();

  /// Visible alerts the user has not yet read.
  List<AlertViewModel> get unreadAlerts =>
      visibleAlerts.where((a) => !readMessages.contains(a.message)).toList();

  int get unreadCount => unreadAlerts.length;

  AlertState copyWith({
    Map<AlertSourceId, List<AlertViewModel>>? alertsBySource,
    Set<String>? scope,
    Set<String>? dismissedMessages,
    Set<String>? readMessages,
    Map<AlertSourceId?, AppError>? sourceHealth,
  }) => AlertState(
    alertsBySource: alertsBySource ?? this.alertsBySource,
    scope: scope ?? this.scope,
    dismissedMessages: dismissedMessages ?? this.dismissedMessages,
    readMessages: readMessages ?? this.readMessages,
    sourceHealth: sourceHealth ?? this.sourceHealth,
  );

  @override
  List<Object?> get props => [
    alertsBySource,
    scope,
    dismissedMessages,
    readMessages,
    sourceHealth,
  ];
}
