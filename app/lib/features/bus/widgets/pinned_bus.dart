import 'package:wheres_the_bus/data/models/bus_models.dart';

/// Pure geometry for the "pin a bus, pick your alight stop" flow. Kept out of
/// the screen's `part` files so it can be unit-tested directly.

int? pinnedBusNextStopIndex({
  required Iterable<BusStopEtaViewModel> etas,
  required List<String> stopUidsInOrder,
  required int direction,
  required String plate,
}) {
  int? best;
  // The estimate's plate is server-normalized; the tapped marker's comes from
  // the raw position feed.
  final wanted = plate.trim().toUpperCase();
  for (final eta in etas) {
    if (eta.direction != direction) continue;
    if (eta.plate.isEmpty || eta.plate != wanted) continue;
    final i = stopUidsInOrder.indexOf(eta.stopUid);
    if (i < 0) continue;
    if (best == null || i < best) best = i;
  }
  return best;
}

/// The earliest stop index a rider can still choose to alight at: the pinned
/// bus's next stop, or the first stop when its position is unknown. Stops at or
/// after this index are pickable targets; earlier ones are dimmed as passed.
int firstAlightIndex(int? nextStopIndex) => nextStopIndex ?? 0;

/// Whether the cell at [index] is a pickable alight target for a pinned bus
/// whose next stop is at [nextStopIndex]. Passed stops (before the bus) return
/// false.
bool isAlightTarget(int index, int? nextStopIndex) =>
    index >= firstAlightIndex(nextStopIndex);

/// Clamps a 提前站數 lead to at least one stop, matching the stepper's floor.
int clampLeadStops(int leadStops) => leadStops < 0 ? 0 : leadStops;
