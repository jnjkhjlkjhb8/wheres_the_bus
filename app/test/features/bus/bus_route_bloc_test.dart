import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/core/errors/app_error.dart';
import 'package:wheres_the_bus/features/bus/bloc/bus_route_bloc.dart';
import 'package:wheres_the_bus/features/bus/bloc/bus_route_event.dart';
import 'package:wheres_the_bus/features/bus/bloc/bus_route_state.dart';

void main() {
  test('BusRouteStreamFailed sets AppError', () async {
    final bloc = BusRouteBloc(subRouteUid: 'TEST', autoStart: false);
    addTearDown(bloc.close);

    final next = expectLater(
      bloc.stream,
      emits(
        isA<BusRouteState>().having(
          (s) => s.error,
          'error',
          isA<OfflineError>(),
        ),
      ),
    );

    bloc.add(const BusRouteStreamFailed(OfflineError()));
    await next;
  });
}
