import 'package:equatable/equatable.dart';
import 'package:wheres_the_bus/data/models/feedback_models.dart';

sealed class FeedbackEvent extends Equatable {
  const FeedbackEvent();

  @override
  List<Object?> get props => [];
}

/// Fired once when the sheet opens. [screen] and [locale] are read from the
/// widget tree by the caller, since the sheet is pushed onto the root
/// navigator and no longer sits under the route it was opened from.
class FeedbackOpened extends FeedbackEvent {
  const FeedbackOpened({required this.screen, required this.locale});

  final String screen;
  final String locale;

  @override
  List<Object?> get props => [screen, locale];
}

/// The rider committed the report. Resubmitting after a failure is the same
/// event; the bloc clears the previous error as it starts.
class FeedbackSubmitted extends FeedbackEvent {
  const FeedbackSubmitted({required this.category, required this.body});

  final FeedbackCategory category;
  final String body;

  @override
  List<Object?> get props => [category, body];
}
