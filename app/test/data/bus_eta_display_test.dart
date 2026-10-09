import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/models/bus_models.dart';
import 'package:wheres_the_bus/features/bus/bloc/bus_route_bloc.dart';

import '../support/helpers/i18n.dart';

void main() {
  BusStopEtaViewModel eta({
    int estimateSeconds = -1,
    String nextBusTime = '',
    int stopStatus = 1,
    int direction = 0,
    int sequence = 1,
  }) => BusStopEtaViewModel(
    stopUid: 'stop',
    direction: direction,
    sequence: sequence,
    estimateSeconds: estimateSeconds,
    nextBusTime: nextBusTime,
    stopStatus: stopStatus,
    vehiclePlates: const [],
  );

  test('bus ETA display uses compact labels', () {
    expect(
      eta(estimateSeconds: 61, stopStatus: 0).displayLabelOf(zhStrings),
      '2分',
    );
    expect(
      eta(nextBusTime: '2026-06-18T08:15:00+08:00').displayLabelOf(zhStrings),
      '08:15',
    );
    expect(eta(nextBusTime: '8:05:00').displayLabelOf(zhStrings), '08:05');
    expect(eta(stopStatus: 3).displayLabelOf(zhStrings), '末班已過');
  });

  test('bus route ETA key prefers direction and stop sequence', () {
    expect(
      BusRouteBloc.etaKey(
        eta(direction: 1, sequence: 7, nextBusTime: '08:15'),
      ),
      'seq:1:7',
    );
  });
}
