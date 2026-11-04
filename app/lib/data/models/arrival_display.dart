import 'package:wheres_the_bus/data/models/bus_models.dart';
import 'package:wheres_the_bus/data/models/eta_format.dart';
import 'package:wheres_the_bus/data/models/eta_status.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';

class ArrivalDisplay {
  const ArrivalDisplay({
    required this.label,
    required this.destination,
    required this.status,
    required this.rank,
    this.crowdLevel = CrowdLevel.unknown,
    this.isLastBus = false,
    this.source = EtaSource.live,
  });

  factory ArrivalDisplay.fromBusStop(AppI18n i18n, BusStopArrival a) {
    final label = a.displayLabelOf(i18n);
    final minutes = a.minutes;
    final serviceState = label != null
        ? EtaStatus.label(label)
        : EtaStatus.unknown();
    final (EtaStatus status, int rank) = switch (a.displayStatus) {
      // 進站中 / 即將進站 say a vehicle is there; a timetable or model time
      // can only ever claim a countdown.
      BusStopDisplayStatus.arriving ||
      BusStopDisplayStatus.departingSoon when !a.source.isLive => (
        EtaStatus.minutes(1),
        3,
      ),
      BusStopDisplayStatus.arriving => (EtaStatus.arriving(), 0),
      BusStopDisplayStatus.departingSoon => (EtaStatus.approaching(), 1),
      BusStopDisplayStatus.minutes when minutes != null => (
        EtaStatus.minutes(minutes),
        minutes + 2,
      ),
      // Not-yet-departed with a scheduled clock time (HH:mm): show the clock
      // but keep the time-based rank so it interleaves with live arrivals by
      // when it actually comes, instead of sinking to the service-state floor.
      BusStopDisplayStatus.notDeparted when minutes != null => (
        serviceState,
        minutes + 2,
      ),
      // Service has ended for the day: sink below every other service-state
      // row (交管不停靠 / 未營運 / unknown), which stay at 9999.
      BusStopDisplayStatus.lastBusPassed => (serviceState, 10000),
      _ => (serviceState, 9999),
    };
    return ArrivalDisplay(
      label: a.routeName,
      destination: a.destination,
      status: status,
      rank: rank,
      crowdLevel: a.crowdLevel,
      isLastBus: a.isLastBus,
      source: a.source,
    );
  }

  factory ArrivalDisplay.fromMetro({
    required String line,
    required String destination,
    required int estimateSeconds,
  }) => ArrivalDisplay(
    label: line,
    destination: destination,
    status: estimateSeconds <= 0
        ? EtaStatus.arriving()
        : EtaStatus.minutesSeconds(estimateSeconds ~/ 60, estimateSeconds % 60),
    rank: estimateSeconds,
  );

  final String label;
  final String destination;
  final EtaStatus status;
  final int rank;

  /// How full the vehicle this arrival describes is, resolved server-side from
  /// its plate. Only Taipei buses report it; metro and every other city leave
  /// it UNKNOWN, and nothing is drawn.
  final CrowdLevel crowdLevel;

  /// Whether the feed confirmed this is the route's last bus of the day (TDX
  /// IsLastBus). Only 公路總局 and the counties it manages report it; everywhere
  /// else it stays false and nothing is marked.
  final bool isLastBus;

  /// Where the time came from. Metro and every other non-bus row is live.
  final EtaSource source;

  /// Whether this arrival is eligible for the coming-soon highlight: only the
  /// soonest ranked row (rank <= 3) qualifies, and only when a vehicle
  /// produced the time. The caller pairs this with the list position so at
  /// most the first row is highlighted.
  bool get isComingSoon => source.isLive && rank <= 3;
}
