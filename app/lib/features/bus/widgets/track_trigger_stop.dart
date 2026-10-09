/// The stop [leadStops] before [alightUid] in travel order — the point where a
/// pinned reminder should fire (提前站數). Clamped to the first stop; returns
/// [alightUid] unchanged when it is not in the list.
String resolveTriggerStopUid(
  List<String> stopUidsInOrder,
  String alightUid,
  int leadStops,
) {
  final i = stopUidsInOrder.indexOf(alightUid);
  if (i < 0) return alightUid;
  final t = (i - leadStops).clamp(0, i);
  return stopUidsInOrder[t];
}
