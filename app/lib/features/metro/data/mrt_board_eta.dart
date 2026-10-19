import 'package:wheres_the_bus/core/grpc/resilient_stream.dart';
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
  MrtRepository? repository,
}) {
  if (trainNumber.isEmpty) return const Stream<int>.empty();
  return resilientStream(
    () => (repository ?? MrtRepository.instance).eta(system, stationId),
    foreground: alwaysForeground,
  ).where((a) => a.trainNumber == trainNumber).map((a) => a.estimateSeconds);
}
