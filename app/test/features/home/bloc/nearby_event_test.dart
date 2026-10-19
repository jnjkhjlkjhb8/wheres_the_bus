import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/features/home/bloc/nearby_event.dart';

void main() {
  test('NearbyRetried carries no props and equals itself', () {
    expect(const NearbyRetried().props, isEmpty);
    expect(const NearbyRetried(), const NearbyRetried());
  });

  test('NearbyRequested props are radius, lat, lon', () {
    const e = NearbyRequested(radius: 5, lat: 1.5, lon: 2.5);
    expect(e.props, [5, 1.5, 2.5]);
    expect(e, const NearbyRequested(radius: 5, lat: 1.5, lon: 2.5));
    expect(e == const NearbyRequested(radius: 5, lat: 1.5), isFalse);
  });

  test('NearbyStationsReceived and NearbyStreamFailed props', () {
    expect(const NearbyStationsReceived([]).props, [<Never>[]]);
    final err = Exception('x');
    expect(NearbyStreamFailed(err).props, [err]);
  });
}
