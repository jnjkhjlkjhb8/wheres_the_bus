import 'package:equatable/equatable.dart';
import 'package:wheres_the_bus/data/models/plan_models.dart';

enum JourneyLegKind { bus, metro, tra, thsr, other }

/// One stop's scheduled time on a rail trackOnly leg. Carried in travel order
/// on [JourneyLeg.railSchedule] so the live tracker can derive 還剩 N 站 +
/// progress + ETA from the timetable after the rail screen is gone.
class RailStopSchedule extends Equatable {
  const RailStopSchedule({required this.name, required this.scheduledArrival});

  final String name;

  /// Arrival at this stop; callers pass departure as the fallback at an
  /// endpoint where arrival is blank.
  final DateTime scheduledArrival;

  @override
  List<Object?> get props => [name, scheduledArrival];
}

JourneyLegKind _kindOf(PlanSection s) => switch (s.identity.routeType) {
  'bus' => JourneyLegKind.bus,
  'mrt' => JourneyLegKind.metro,
  'tra' => JourneyLegKind.tra,
  'thsr' => JourneyLegKind.thsr,
  _ => switch (s.transport.mode) {
    'bus' => JourneyLegKind.bus,
    'subway' || 'metro' => JourneyLegKind.metro,
    'train' || 'rail' => JourneyLegKind.tra,
    'highSpeedTrain' => JourneyLegKind.thsr,
    _ => JourneyLegKind.other,
  },
};

class JourneyLeg extends Equatable {
  const JourneyLeg({
    required this.kind,
    required this.routeLabel,
    required this.boardStop,
    required this.alightStop,
    required this.stopNames,
    required this.identity,
    required this.leadingWalkMinutes,
    required this.scheduledDeparture,
    required this.scheduledArrival,
    required this.boardLocation,
    required this.stopLocations,
    this.railSchedule = const [],
  });

  static List<JourneyLeg> legsFromRoute(PlanRoute route) {
    final legs = <JourneyLeg>[];
    var pendingWalkSeconds = 0;
    for (final section in route.sections) {
      if (section.type != 'transit') {
        pendingWalkSeconds += section.travelSummary.duration;
        continue;
      }
      final headsign = section.transport.headsign;
      final label = section.transport.shortName.isEmpty
          ? section.transport.name
          : section.transport.shortName;
      legs.add(
        JourneyLeg(
          kind: _kindOf(section),
          routeLabel: headsign.isEmpty ? label : '$label 往$headsign',
          boardStop: section.departure.name,
          alightStop: section.arrival.name,
          stopNames: [for (final s in section.intermediateStops) s.name],
          identity: section.identity,
          leadingWalkMinutes: (pendingWalkSeconds / 60).ceil(),
          scheduledDeparture: DateTime.tryParse(section.departure.time),
          scheduledArrival: DateTime.tryParse(section.arrival.time),
          boardLocation: section.departure.location,
          stopLocations: [
            for (final s in section.intermediateStops) s.location,
            section.arrival.location,
          ],
        ),
      );
      pendingWalkSeconds = 0;
    }
    return legs;
  }

  final JourneyLegKind kind;
  final String routeLabel;
  final String boardStop;
  final String alightStop;
  final List<String> stopNames;
  final PlanIdentity identity;
  final int leadingWalkMinutes;
  final DateTime? scheduledDeparture;
  final DateTime? scheduledArrival;
  final PlanPoint boardLocation;

  final List<PlanPoint> stopLocations;

  /// Board→alight scheduled stop times for a rail trackOnly leg (empty for
  /// every other leg). Drives schedule-derived 還剩 N 站 / progress / ETA,
  /// offset by live TRA delay. `railSchedule.last` is the alight stop.
  final List<RailStopSchedule> railSchedule;

  @override
  List<Object?> get props => [
    kind,
    routeLabel,
    boardStop,
    alightStop,
    stopNames,
    identity,
    leadingWalkMinutes,
    scheduledDeparture,
    scheduledArrival,
    boardLocation,
    stopLocations,
    railSchedule,
  ];
}
