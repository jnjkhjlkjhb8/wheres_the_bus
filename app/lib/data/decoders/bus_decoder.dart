import 'package:wheres_the_bus/data/generated/bus.pb.dart';
import 'package:wheres_the_bus/data/models/bus_models.dart';
import 'package:wheres_the_bus/data/models/bus_route_detail.dart';
import 'package:wheres_the_bus/data/models/eta_format.dart';

class BusDecoder {
  const BusDecoder._();
  static const BusDecoder instance = BusDecoder._();

  List<BusStopEtaViewModel> decodeRouteEta(
    Bus_RouteArrival arrival, {
    DateTime? now,
  }) {
    final at = now ?? DateTime.now();
    return arrival.stops.map((s) {
      final arrivalUnix = s.arrivalUnix.toInt();
      // Derive the countdown from the absolute arrival instant when the server
      // sent one, else fall back to the server estimate. A just-passed instant
      // clamps to 0, which stopStatus 0 reads as 進站中.
      final estimateSeconds = etaRemainingSeconds(
        arrivalUnix: arrivalUnix,
        serverEstimateSeconds: s.estimate,
        now: at,
      );
      return BusStopEtaViewModel(
        stopUid: s.stopUid,
        direction: s.direction,
        sequence: s.stopSequence,
        estimateSeconds: estimateSeconds,
        nextBusTime: s.nextBusTime,
        stopStatus: s.stopStatus,
        arrivalUnix: arrivalUnix,
        plate: s.plateNumb,
        isLastBus: s.isLastBus,
        vehiclePlates: s.buses.map((b) => b.plateNumb).toList(),
        vehicles: [
          for (final b in s.buses)
            if (b.positionLat != 0 || b.positionLon != 0)
              BusVehiclePosition(
                plate: b.plateNumb,
                lat: b.positionLat,
                lon: b.positionLon,
                azimuth: b.azimuth,
                dutyStatus: b.dutyStatus,
                busStatus: b.busStatus,
                gpsTimeUnix: b.gpsTimeUnix.toInt(),
              ),
        ],
      );
    }).toList();
  }

  /// Decodes a station-group ETA frame into per-route arrivals. [now] is
  /// injectable for deterministic decode; production passes the wall clock.
  List<BusStopArrival> decodeStationEta(
    Resp_Bus_station_eta resp, {
    DateTime? now,
  }) {
    final at = now ?? DateTime.now();
    return resp.data.routes.map((r) {
      final arrivalUnix = r.arrivalUnix.toInt();
      final estimateSeconds = etaRemainingSeconds(
        arrivalUnix: arrivalUnix,
        serverEstimateSeconds: r.estimate,
        now: at,
      );
      return BusStopArrival(
        stationId: r.stopUid,
        subRouteUid: r.subRouteUid,
        routeName: r.routeName,
        // Terminal stop name from static data; direction label only when the
        // server knows no terminal for this subroute+direction.
        destination: r.destination.isNotEmpty
            ? r.destination
            : (r.direction == 1 ? '返程' : '去程'),
        estimateSeconds: estimateSeconds,
        nextBusTime: r.nextBusTime,
        stopStatus: r.stopStatus,
        arrivalUnix: arrivalUnix,
        crowdLevel: crowdLevelOf(r.crowdLevel),
        isLastBus: r.isLastBus,
      );
    }).toList();
  }

  /// Decodes a station group's member stops. An empty [group] members list
  /// yields an empty list rather than throwing.
  List<BusStationMember> decodeStationMembers(Bus_StationGroup group) {
    return group.members
        .map(
          (m) => BusStationMember(
            stationUid: m.stationUid,
            stationId: m.stationId,
            stationName: m.stationName,
            lat: m.positionLat,
            lon: m.positionLon,
          ),
        )
        .toList();
  }

  BusRouteViewModel decodeStatic(Bus_subroute route) {
    final dir0 = route.directions[0];
    final dir1 = route.directions[1];
    return BusRouteViewModel(
      subRouteUid: route.subRouteUID,
      routeName: route.routeName,
      subRouteName: route.subRouteName,
      departureStopName: route.departureStopName,
      destinationStopName: route.destinationStopName,
      city: route.city,
      headsignGo: dir0?.destinationStopName ?? '',
      headsignReturn: dir1?.destinationStopName ?? '',
      operators: route.operators.map(_operator).toList(),
      stopsGo: dir0?.stops.map(_stop).toList() ?? [],
      stopsReturn: dir1?.stops.map(_stop).toList() ?? [],
      geometryGo: dir0?.geometry ?? '',
      geometryReturn: dir1?.geometry ?? '',
      schedulesGo: dir0?.schedules.map(_service).toList() ?? [],
      schedulesReturn: dir1?.schedules.map(_service).toList() ?? [],
      fare: route.hasFare() ? _fare(route.fare) : null,
    );
  }

  // The proto packs two shapes into one message: for a fixed timetable entry
  // the headway fields carry the origin stop's arrival/departure clock times,
  // for a headway entry they carry the minutes.
  BusServiceEntry _service(Bus_Schedule s) => BusServiceEntry(
    isTimetable: s.isTimetable,
    serviceDay: s.serviceDay,
    tripId: s.tripid,
    isLowFloor: s.islowfloor,
    departureTime: s.isTimetable
        ? (s.maxHeadwayMinsDepartureTime.isNotEmpty
              ? s.maxHeadwayMinsDepartureTime
              : s.minHeadwayMinsArrivalTime)
        : '',
    startTime: s.isTimetable ? '' : s.startTime,
    endTime: s.isTimetable ? '' : s.endTime,
    minHeadwayMins: s.isTimetable ? '' : s.minHeadwayMinsArrivalTime,
    maxHeadwayMins: s.isTimetable ? '' : s.maxHeadwayMinsDepartureTime,
  );

  BusOperatorInfo _operator(BusOperator o) => BusOperatorInfo(
    name: o.operatorName,
    phone: o.operatorPhone,
    url: o.operatorUrl,
  );

  BusFareInfo _fare(Bus_Fare f) => BusFareInfo(
    pricingType: f.farePricingType,
    isFreeBus: f.isFreeBus,
    sectionFaresJson: f.sectionFaresJson,
    stageFaresJson: f.stageFaresJson,
    odFaresJson: f.odFaresJson,
  );

  BusStopModel _stop(Bus_stop s) => BusStopModel(
    stopUid: s.stopUID,
    stopName: s.stopName,
    sequence: s.stopSequence,
    lat: s.positionLat,
    lon: s.positionLon,
  );

  BusDailyTimetable decodeDaily(Bus_DailyTimetables proto) {
    return BusDailyTimetable(
      directions: {
        for (final entry in proto.direction.entries)
          entry.key: [
            for (final t in entry.value.dailyTimetables)
              BusDailyTrip(
                tripId: t.tripID,
                isLowFloor: t.isLowFloor,
                stopTimes: [
                  for (final s in t.stopTimes)
                    BusStopTime(
                      stopSequence: s.stopSequence,
                      departureTime: s.departureTime,
                      arrivalTime: s.arrivalTime,
                    ),
                ],
              ),
          ],
      },
    );
  }
}

/// Maps the wire crowding enum onto the app's own. An unrecognised value is
/// [CrowdLevel.unknown]: a level this build does not know is not a reading it
/// can show.
CrowdLevel crowdLevelOf(BusCrowdLevel wire) => switch (wire) {
  BusCrowdLevel.BUS_CROWD_COMFORTABLE => CrowdLevel.comfortable,
  BusCrowdLevel.BUS_CROWD_NORMAL => CrowdLevel.normal,
  BusCrowdLevel.BUS_CROWD_CROWDED => CrowdLevel.crowded,
  _ => CrowdLevel.unknown,
};
