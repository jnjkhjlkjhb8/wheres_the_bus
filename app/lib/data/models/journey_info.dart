class JourneyInfo {
  const JourneyInfo({
    required this.toStationId,
    required this.fareNt,
    required this.halfFareNt,
    required this.travelTimeMin,
  });

  factory JourneyInfo.fromRow(Map<String, dynamic> row) => JourneyInfo(
    toStationId: row['to_station_id'] as String,
    fareNt: row['fare_nt'] as int,
    halfFareNt: (row['half_fare_nt'] as int?) ?? 0,
    // 0 = unknown/unsourced (feed omitted TravelTime); callers render it as "—".
    travelTimeMin: (row['travel_time_min'] as int?) ?? 0,
  );

  final String toStationId;
  final int fareNt;
  final int halfFareNt;
  final int travelTimeMin;
}
