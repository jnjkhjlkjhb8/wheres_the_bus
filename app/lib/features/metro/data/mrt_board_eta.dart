import 'package:wheres_the_bus/data/repositories/mrt_repository.dart';

/// Seconds until the tracked train reaches the boarding station.
typedef BoardEtaStream =
    Stream<int> Function({
      required String system,
      required String stationId,
      required String trainNumber,
    });

Stream<int> defaultBoardEtaStream({
  required String system,
  required String stationId,
  required String trainNumber,
}) {
  if (trainNumber.isEmpty) return const Stream<int>.empty();
  return MrtRepository.instance
      .eta(system, stationId)
      .where((a) => a.trainNumber == trainNumber)
      .map((a) => a.estimateSeconds);
}
