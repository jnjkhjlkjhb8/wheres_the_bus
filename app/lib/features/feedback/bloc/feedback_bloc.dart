import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:grpc/grpc.dart';
import 'package:wheres_the_bus/core/errors/app_error.dart';
import 'package:wheres_the_bus/data/models/feedback_models.dart';
import 'package:wheres_the_bus/data/repositories/feedback_repository.dart';
import 'package:wheres_the_bus/features/feedback/bloc/feedback_event.dart';
import 'package:wheres_the_bus/features/feedback/bloc/feedback_state.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';

class FeedbackBloc extends Bloc<FeedbackEvent, FeedbackState> {
  FeedbackBloc({FeedbackRepository? repository})
    : _repository = repository ?? FeedbackRepository.instance,
      super(const FeedbackState()) {
    on<FeedbackOpened>(_onOpened);
    on<FeedbackSubmitted>(_onSubmitted);
  }

  final FeedbackRepository _repository;

  Future<void> _onOpened(
    FeedbackOpened event,
    Emitter<FeedbackState> emit,
  ) async {
    final diagnostics = await _repository.collect(
      screen: event.screen,
      locale: event.locale,
    );
    emit(state.copyWith(diagnostics: diagnostics));
  }

  Future<void> _onSubmitted(
    FeedbackSubmitted event,
    Emitter<FeedbackState> emit,
  ) async {
    emit(state.copyWith(status: FeedbackStatus.submitting, clearError: true));
    try {
      final receipt = await _repository.submit(
        category: event.category,
        body: event.body,
        diagnostics: state.diagnostics ?? const FeedbackDiagnostics(),
      );
      emit(state.copyWith(status: FeedbackStatus.sent, receipt: receipt));
    } on Object catch (error) {
      emit(
        state.copyWith(
          status: FeedbackStatus.composing,
          error: describeSubmitFailure(error),
        ),
      );
    }
  }
}

sealed class FeedbackFailure extends Equatable {
  const FeedbackFailure();

  String messageOf(AppI18n i18n);
}

enum FeedbackRejection { rateLimited, unverified, rejected }

/// A server rejection the rider can act on directly.
class FeedbackRejected extends FeedbackFailure {
  const FeedbackRejected(this.reason);

  final FeedbackRejection reason;

  @override
  String messageOf(AppI18n i18n) => switch (reason) {
    FeedbackRejection.rateLimited => i18n.feedbackErrorRateLimited,
    FeedbackRejection.unverified => i18n.feedbackErrorUnverified,
    FeedbackRejection.rejected => i18n.feedbackErrorRejected,
  };

  @override
  List<Object?> get props => [reason];
}

/// Anything else, described in the app-wide error vocabulary.
class FeedbackTransportFailure extends FeedbackFailure {
  const FeedbackTransportFailure(this.error);

  final AppError error;

  @override
  String messageOf(AppI18n i18n) => error.hintOf(i18n);

  @override
  List<Object?> get props => [error];
}

FeedbackFailure describeSubmitFailure(Object error) {
  if (error is GrpcError) {
    switch (error.code) {
      case StatusCode.resourceExhausted:
        return const FeedbackRejected(FeedbackRejection.rateLimited);
      case StatusCode.permissionDenied:
      case StatusCode.unauthenticated:
        return const FeedbackRejected(FeedbackRejection.unverified);
      case StatusCode.invalidArgument:
        return const FeedbackRejected(FeedbackRejection.rejected);
    }
  }
  return FeedbackTransportFailure(AppError.from(error));
}
