import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/models/bus_models.dart';

BusRouteViewModel _route({
  List<BusStopModel> go = const [],
  List<BusStopModel> back = const [],
}) => BusRouteViewModel(
  subRouteUid: 'TEST',
  routeName: '201',
  subRouteName: '201A',
  departureStopName: '',
  destinationStopName: '',
  city: 'YunlinCounty',
  headsignGo: '',
  headsignReturn: '雲林科技大學',
  stopsGo: go,
  stopsReturn: back,
);

const _stop = BusStopModel(
  stopUid: 'S1',
  stopName: '雲林科技大學',
  sequence: 1,
  lat: 23.696283,
  lon: 120.533386,
);

void main() {
  test('soleDirection picks the populated leg', () {
    // YUN0201A2 / TPE157462 shape: TDX publishes the return leg only.
    expect(_route(back: const [_stop]).soleDirection, 1);
    expect(_route(go: const [_stop]).soleDirection, 0);
    expect(
      _route(go: const [_stop], back: const [_stop]).soleDirection,
      isNull,
    );
    expect(_route().soleDirection, isNull);
  });
}
