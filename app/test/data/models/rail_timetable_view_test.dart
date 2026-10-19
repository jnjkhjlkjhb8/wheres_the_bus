import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/models/rail_timetable_view.dart';

RailTimetableView _view({
  String trainNo = '123',
  String trainType = '自強',
  String originName = '臺北',
  String destinationName = '臺中',
  String departureTime = '08:00',
  String arrivalTime = '10:00',
  String travelTime = '02:00',
}) => RailTimetableView(
  trainNo: trainNo,
  trainType: trainType,
  originName: originName,
  destinationName: destinationName,
  departureTime: departureTime,
  arrivalTime: arrivalTime,
  travelTime: travelTime,
);

void main() {
  test('rail timetable value equality retains every trip and time field', () {
    final view = _view();
    final equal = _view();
    expect(identical(view, equal), isFalse);
    expect(view, equal);
    expect(view.hashCode, equal.hashCode);
    final changed = [
      _view(trainNo: '124'),
      _view(trainType: '區間'),
      _view(originName: '板橋'),
      _view(destinationName: '彰化'),
      _view(departureTime: '08:05'),
      _view(arrivalTime: '10:05'),
      _view(travelTime: '02:05'),
    ];
    for (final other in changed) {
      expect(view, isNot(other));
    }
    expect({view, equal, ...changed}, hasLength(8));
  });
}
