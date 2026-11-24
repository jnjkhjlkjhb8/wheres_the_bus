import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:wheres_the_bus/features/go/bloc/plan_preview_event.dart';
import 'package:wheres_the_bus/features/go/bloc/plan_preview_state.dart';

class PlanPreviewBloc extends Bloc<PlanPreviewEvent, PlanPreviewState> {
  PlanPreviewBloc() : super(const PlanPreviewState()) {
    on<PreviewOpened>(
      (event, emit) => emit(PlanPreviewState(route: event.route)),
    );
    on<PreviewClosed>((_, emit) => emit(const PlanPreviewState()));
    on<PreviewRoutesRefreshed>(_onRoutesRefreshed);
  }

  void _onRoutesRefreshed(
    PreviewRoutesRefreshed event,
    Emitter<PlanPreviewState> emit,
  ) {
    final route = state.route;
    if (route == null) return;
    emit(PlanPreviewState(route: route.refreshedFrom(event.routes)));
  }
}
