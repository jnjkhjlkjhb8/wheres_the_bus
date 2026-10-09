import 'package:wheres_the_bus/data/generated/mrt.pb.dart';
import 'package:wheres_the_bus/data/models/metro_models.dart';

class MrtDecoder {
  const MrtDecoder._();
  static const MrtDecoder instance = MrtDecoder._();

  MetroLiveArrival decodeEta(Mrt_live live) {
    return MetroLiveArrival(
      line: live.lineID,
      destination: live.destinationStationName,
      estimateSeconds: live.estimateTime,
      stationId: live.stationID,
      destinationStationId: live.destinationStaionID,
      system: live.system,
      trainNumber: live.trainNumber,
      cn1: live.cN1,
      congestion: _congestion(live),
    );
  }

  static List<int> _congestion(Mrt_live live) {
    if (!live.hasWeight()) return const [];
    final w = live.weight;
    final out = <int>[];
    for (final raw in [
      w.cart1L,
      w.cart2L,
      w.cart3L,
      w.cart4L,
      w.cart5L,
      w.cart6L,
    ]) {
      if (raw.isEmpty) continue;
      final level = int.tryParse(raw);
      if (level != null) out.add(level);
    }
    return out;
  }
}
