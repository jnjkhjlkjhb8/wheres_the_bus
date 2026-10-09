import 'package:equatable/equatable.dart';
import 'package:wheres_the_bus/data/models/bus_route_detail.dart';
import 'package:wheres_the_bus/data/models/eta_format.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';

enum BusArrivalStatus { arriving, approaching, minutes, unknown }

class BusVehiclePosition extends Equatable {
  const BusVehiclePosition({
    required this.plate,
    required this.lat,
    required this.lon,
    required this.azimuth,
    this.dutyStatus = 0,
    this.busStatus = 0,
    this.gpsTimeUnix = 0,
  });

  final String plate;
  final double lat;
  final double lon;
  final int azimuth;

  /// TDX 勤務狀態: `0` 正常, `1` 開始, `2` 結束.
  final int dutyStatus;

  /// TDX 行車狀況: `0` 正常, `1` 車禍, `2` 故障, `3` 塞車, `4` 緊急, `5` 加油,
  /// `98` 偏移, `99` 非營運, `100` 客滿, `101` 包車; 其餘 不明.
  final int busStatus;

  /// GPS fix time in epoch seconds; 0 when the feed reported none.
  final int gpsTimeUnix;

  @override
  List<Object?> get props => [
    plate,
    lat,
    lon,
    azimuth,
    dutyStatus,
    busStatus,
    gpsTimeUnix,
  ];
}

class BusStopEtaViewModel extends Equatable {
  const BusStopEtaViewModel({
    required this.stopUid,
    required this.direction,
    required this.sequence,
    required this.estimateSeconds,
    required this.nextBusTime,
    required this.stopStatus,
    required this.vehiclePlates,
    this.arrivalUnix = 0,
    this.vehicles = const [],
    this.plate = '',
    this.isLastBus = false,
  });

  final String stopUid;
  final int direction;
  final int sequence;
  final int estimateSeconds;
  final String nextBusTime;
  final int stopStatus;
  final List<String> vehiclePlates;
  final int arrivalUnix;
  final List<BusVehiclePosition> vehicles;

  /// The vehicle this estimate describes, uppercase-trimmed by the server.
  /// Empty when TDX sent no plate. Distinct from [vehiclePlates], which is
  /// the whole route's live fleet and is identical on every stop.
  final String plate;

  /// TDX IsLastBus: the feed confirmed the route's last bus is running. False
  /// also means "never computed", so it may not be read as 末班車已過 on its own.
  final bool isLastBus;

  int get estimateMinutes => etaCeilMinutes(estimateSeconds);

  BusStopEtaViewModel decayed(DateTime now) {
    if (arrivalUnix <= 0) return this;
    return copyWith(
      estimateSeconds: etaRemainingSeconds(
        arrivalUnix: arrivalUnix,
        serverEstimateSeconds: estimateSeconds,
        now: now,
      ),
    );
  }

  BusStopEtaViewModel copyWith({int? estimateSeconds, int? stopStatus}) =>
      BusStopEtaViewModel(
        stopUid: stopUid,
        direction: direction,
        sequence: sequence,
        estimateSeconds: estimateSeconds ?? this.estimateSeconds,
        nextBusTime: nextBusTime,
        stopStatus: stopStatus ?? this.stopStatus,
        vehiclePlates: vehiclePlates,
        arrivalUnix: arrivalUnix,
        vehicles: vehicles,
        plate: plate,
        isLastBus: isLastBus,
      );

  String? displayLabelOf(AppI18n i18n) => busStopDisplayLabel(
    i18n: i18n,
    estimateSeconds: estimateSeconds,
    stopStatus: stopStatus,
    nextBusTime: nextBusTime,
  );

  BusArrivalStatus get status {
    if (stopStatus == 0 && estimateSeconds == 0) {
      return BusArrivalStatus.arriving;
    }
    if (estimateSeconds > 0 && estimateSeconds < 60) {
      return BusArrivalStatus.approaching;
    }
    if (estimateSeconds > 0) return BusArrivalStatus.minutes;
    return BusArrivalStatus.unknown;
  }

  @override
  List<Object?> get props => [
    stopUid,
    direction,
    sequence,
    estimateSeconds,
    nextBusTime,
    stopStatus,
    vehiclePlates,
    arrivalUnix,
    vehicles,
    plate,
    isLastBus,
  ];
}

/// A member stop of a station group, resolved to the fields the stop screen
/// reads. A validated domain type: no proto leaks past the decoder.
class BusStationMember {
  const BusStationMember({
    required this.stationUid,
    required this.stationId,
    required this.stationName,
    required this.lat,
    required this.lon,
  });

  final String stationUid;
  final String stationId;
  final String stationName;
  final double lat;
  final double lon;
}

enum CrowdLevel { unknown, comfortable, normal, crowded }

class BusStopArrival extends Equatable {
  const BusStopArrival({
    required this.stationId,
    required this.subRouteUid,
    required this.routeName,
    required this.destination,
    required this.estimateSeconds,
    this.nextBusTime = '',
    this.stopStatus = 0,
    this.arrivalUnix = 0,
    this.crowdLevel = CrowdLevel.unknown,
    this.isLastBus = false,
  });

  final String stationId;
  final String subRouteUid;
  final String routeName;
  final String destination;
  final int estimateSeconds;
  final String nextBusTime;

  /// TDX StopStatus (0 = normal, 1 = not departed, 2 = traffic control,
  /// 3 = last bus passed, 4 = not operating today).
  final int stopStatus;

  /// Absolute arrival instant (Unix seconds), or 0 when the server sent none.
  final int arrivalUnix;

  /// How full the arriving vehicle is. [CrowdLevel.unknown] whenever the server
  /// could not pair a reading to this estimate's plate, which is every city but
  /// Taipei.
  final CrowdLevel crowdLevel;

  /// TDX IsLastBus; see [BusStopEtaViewModel.isLastBus].
  final bool isLastBus;

  /// Remaining whole minutes (ceil), or null when no positive estimate exists.
  int? get minutes {
    final m = etaCeilMinutes(estimateSeconds);
    return m > 0 ? m : null;
  }

  BusStopDisplayStatus get displayStatus => busStopDisplayStatus(
    estimateSeconds: estimateSeconds,
    stopStatus: stopStatus,
  );

  /// User-facing label ('2分', '進站中', a clock time, or a service state), or
  /// null when nothing is known.
  String? displayLabelOf(AppI18n i18n) => busStopDisplayLabel(
    i18n: i18n,
    estimateSeconds: estimateSeconds,
    stopStatus: stopStatus,
    nextBusTime: nextBusTime,
  );

  bool get isArriving => displayStatus == BusStopDisplayStatus.arriving;

  /// Re-derives [estimateSeconds] from [arrivalUnix] against [now] so the
  /// countdown decays between server pushes. Leaves the arrival unchanged when
  /// no absolute instant was sent.
  BusStopArrival decayed(DateTime now) {
    if (arrivalUnix <= 0) return this;
    return BusStopArrival(
      stationId: stationId,
      subRouteUid: subRouteUid,
      routeName: routeName,
      destination: destination,
      estimateSeconds: etaRemainingSeconds(
        arrivalUnix: arrivalUnix,
        serverEstimateSeconds: estimateSeconds,
        now: now,
      ),
      nextBusTime: nextBusTime,
      stopStatus: stopStatus,
      arrivalUnix: arrivalUnix,
      crowdLevel: crowdLevel,
      isLastBus: isLastBus,
    );
  }

  @override
  List<Object?> get props => [
    stationId,
    subRouteUid,
    routeName,
    destination,
    estimateSeconds,
    nextBusTime,
    stopStatus,
    arrivalUnix,
    crowdLevel,
    isLastBus,
  ];
}

class BusStopModel extends Equatable {
  const BusStopModel({
    required this.stopUid,
    required this.stopName,
    required this.sequence,
    this.lat = 0,
    this.lon = 0,
  });
  final String stopUid;
  final String stopName;
  final int sequence;
  final double lat;
  final double lon;
  @override
  List<Object?> get props => [stopUid, stopName, sequence, lat, lon];
}

class BusRouteViewModel extends Equatable {
  const BusRouteViewModel({
    required this.subRouteUid,
    required this.routeName,
    required this.subRouteName,
    required this.departureStopName,
    required this.destinationStopName,
    required this.city,
    required this.headsignGo,
    required this.headsignReturn,
    this.operators = const [],
    this.stopsGo = const [],
    this.stopsReturn = const [],
    this.geometryGo = '',
    this.geometryReturn = '',
    this.schedulesGo = const [],
    this.schedulesReturn = const [],
    this.fare,
  });

  final String subRouteUid;
  final String routeName;
  final String subRouteName;
  final String departureStopName;
  final String destinationStopName;
  final String city;
  final String headsignGo;
  final String headsignReturn;
  final List<BusOperatorInfo> operators;
  final List<BusStopModel> stopsGo;
  final List<BusStopModel> stopsReturn;
  final String geometryGo;
  final String geometryReturn;

  /// Weekly service pattern per direction; empty when TDX publishes no
  /// Bus/Schedule for the sub-route, in which case only today's timetable is
  /// knowable.
  final List<BusServiceEntry> schedulesGo;
  final List<BusServiceEntry> schedulesReturn;
  final BusFareInfo? fare;

  int? get soleDirection {
    if (stopsGo.isEmpty && stopsReturn.isNotEmpty) return 1;
    if (stopsReturn.isEmpty && stopsGo.isNotEmpty) return 0;
    return null;
  }

  @override
  List<Object?> get props => [
    subRouteUid,
    routeName,
    subRouteName,
    departureStopName,
    destinationStopName,
    city,
    headsignGo,
    headsignReturn,
    operators,
    fare,
  ];
}
