import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/models/rail_station_board.dart';

RailStationDeparture _departure({
  String trainNo = '123',
  String trainType = '自強',
  String destination = '花蓮',
  String departureTime = '08:00:00',
  String serviceDate = '2026-08-31',
  bool isSuspended = false,
  String remark = '',
}) => RailStationDeparture(
  trainNo: trainNo,
  trainType: trainType,
  destination: destination,
  departureTime: departureTime,
  serviceDate: serviceDate,
  isSuspended: isSuspended,
  remark: remark,
);

void main() {
  test('directions travel on the wire as 0 and 1', () {
    expect(RailBoardDirection.forward.wire, 0);
    expect(RailBoardDirection.reverse.wire, 1);
    expect(RailBoardDirection.values, hasLength(2));
  });

  test('a departure is on time and unremarked by default', () {
    const departure = RailStationDeparture(
      trainNo: '123',
      trainType: '自強',
      destination: '花蓮',
      departureTime: '08:00:00',
      serviceDate: '2026-08-31',
    );
    expect(departure.isSuspended, isFalse);
    expect(departure.remark, '');
  });

  test('every field takes part in equality', () {
    expect(_departure(), _departure());
    expect(_departure().hashCode, _departure().hashCode);
    final others = [
      _departure(trainNo: '124'),
      _departure(trainType: '區間'),
      _departure(destination: '台東'),
      _departure(departureTime: '08:01:00'),
      _departure(serviceDate: '2026-09-01'),
      _departure(isSuspended: true),
      _departure(remark: '行駛支線'),
    ];
    for (final other in others) {
      expect(other, isNot(_departure()));
    }
  });
}
