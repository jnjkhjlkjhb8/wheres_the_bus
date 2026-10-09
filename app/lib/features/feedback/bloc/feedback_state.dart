import 'package:equatable/equatable.dart';
import 'package:wheres_the_bus/data/models/feedback_models.dart';
import 'package:wheres_the_bus/features/feedback/bloc/feedback_bloc.dart';

enum FeedbackStatus {
  /// The rider is writing. Also where a failed submission returns to, with
  /// [FeedbackState.error] set and everything they typed still in the field.
  composing,
  submitting,

  /// Stored server-side. Terminal: the sheet shows the receipt from here.
  sent,
}

class FeedbackState extends Equatable {
  const FeedbackState({
    this.status = FeedbackStatus.composing,
    this.diagnostics,
    this.receipt,
    this.error,
  });

  final FeedbackStatus status;

  /// Null until the open event has resolved. The sheet discloses this before
  /// the rider can submit, so the submit control waits on it.
  final FeedbackDiagnostics? diagnostics;
  final FeedbackReceipt? receipt;

  /// Rider-facing explanation of the last failed submission.
  final FeedbackFailure? error;

  bool get submitting => status == FeedbackStatus.submitting;

  FeedbackState copyWith({
    FeedbackStatus? status,
    FeedbackDiagnostics? diagnostics,
    FeedbackReceipt? receipt,
    FeedbackFailure? error,
    bool clearError = false,
  }) => FeedbackState(
    status: status ?? this.status,
    diagnostics: diagnostics ?? this.diagnostics,
    receipt: receipt ?? this.receipt,
    error: clearError ? null : error ?? this.error,
  );

  @override
  List<Object?> get props => [status, diagnostics, receipt, error];
}
