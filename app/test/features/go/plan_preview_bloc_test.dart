import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/models/plan_models.dart';
import 'package:wheres_the_bus/features/go/bloc/plan_preview_bloc.dart';
import 'package:wheres_the_bus/features/go/bloc/plan_preview_event.dart';
import 'package:wheres_the_bus/features/go/bloc/plan_preview_state.dart';

void main() {
  test('starts with nothing previewed', () {
    final bloc = PlanPreviewBloc();
    addTearDown(bloc.close);
    expect(bloc.state, const PlanPreviewState());
    expect(bloc.state.previewing, isFalse);
  });

  test('opening a route previews it, closing clears it', () async {
    final bloc = PlanPreviewBloc();
    addTearDown(bloc.close);
    final route = _route('a');

    bloc.add(PreviewOpened(route));
    await bloc.stream.first;
    expect(bloc.state.route, route);
    expect(bloc.state.previewing, isTrue);

    bloc.add(const PreviewClosed());
    await bloc.stream.first;
    expect(bloc.state.route, isNull);
  });

  test(
    'a refresh swaps in the same itinerary from the newer results',
    () async {
      final bloc = PlanPreviewBloc();
      addTearDown(bloc.close);
      final held = _route('a');
      final withGeometry = _route('a', travelTime: 900);

      bloc.add(PreviewOpened(held));
      await bloc.stream.first;
      bloc.add(PreviewRoutesRefreshed([_route('b'), withGeometry]));
      await bloc.stream.first;

      expect(bloc.state.route, same(withGeometry));
    },
  );

  test('a refresh keeps the route when it is not among the results', () async {
    final bloc = PlanPreviewBloc();
    addTearDown(bloc.close);
    final held = _route('a');

    bloc.add(PreviewOpened(held));
    await bloc.stream.first;
    bloc.add(PreviewRoutesRefreshed([_route('b')]));
    await pumpEventQueue();

    expect(bloc.state.route, same(held));
  });

  test('a refresh with nothing previewed opens nothing', () async {
    final bloc = PlanPreviewBloc();
    addTearDown(bloc.close);

    bloc.add(PreviewRoutesRefreshed([_route('a')]));
    await pumpEventQueue();

    expect(bloc.state.route, isNull);
  });
}

PlanRoute _route(String id, {int travelTime = 600}) => PlanRoute(
  travelTime: travelTime,
  startTime: '12:00',
  endTime: '12:10',
  transfers: 0,
  sections: const [],
  id: id,
);
