import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/models/bus_route_detail.dart';

void main() {
  test('tripsForDirection returns only that direction', () {
    const detail = BusDailyTimetable(
      directions: {
        0: [
          BusDailyTrip(
            tripId: 'A',
            isLowFloor: true,
            stopTimes: [
              BusStopTime(
                stopSequence: 1,
                departureTime: '08:00',
                arrivalTime: '',
              ),
            ],
          ),
        ],
        1: [],
      },
    );
    expect(detail.tripsForDirection(0), hasLength(1));
    expect(detail.tripsForDirection(0).first.tripId, 'A');
    expect(detail.tripsForDirection(1), isEmpty);
    expect(detail.tripsForDirection(9), isEmpty); // missing direction
  });
}
