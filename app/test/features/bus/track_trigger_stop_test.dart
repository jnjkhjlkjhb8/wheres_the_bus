import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/features/bus/widgets/track_trigger_stop.dart';

void main() {
  const stops = ['A', 'B', 'C', 'D', 'E'];
  test(
    'lead 2 before D → B',
    () => expect(resolveTriggerStopUid(stops, 'D', 2), 'B'),
  );
  test(
    'lead clamps to first stop',
    () => expect(resolveTriggerStopUid(stops, 'B', 5), 'A'),
  );
  test(
    'lead 0 → the alight stop itself',
    () => expect(resolveTriggerStopUid(stops, 'C', 0), 'C'),
  );
  test(
    'unknown alight → returns alight',
    () => expect(resolveTriggerStopUid(stops, 'Z', 2), 'Z'),
  );
}
