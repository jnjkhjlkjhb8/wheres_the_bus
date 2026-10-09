import 'package:equatable/equatable.dart';
import 'package:wheres_the_bus/data/tracking/journey_models.dart';

class TrackCard extends Equatable {
  const TrackCard({
    required this.routeLabel,
    required this.targetStopName,
    required this.stopsRemaining,
    required this.progress,
    this.plate,
    this.etaSeconds,
  });

  /// Builds a card from a MaaS [JourneyLeg] while the user is riding it.
  /// [nextStopIndex] indexes [JourneyLeg.stopLocations] (intermediate stops
  /// + alight stop, in travel order) at the next upcoming stop.
  factory TrackCard.fromRidingLeg(
    JourneyLeg leg, {
    required int nextStopIndex,
    int? etaSeconds,
  }) {
    final totalStops = leg.stopLocations.length;
    return TrackCard(
      routeLabel: leg.routeLabel,
      targetStopName: leg.alightStop,
      stopsRemaining: (totalStops - nextStopIndex).clamp(0, totalStops),
      progress: totalStops == 0
          ? 0.0
          : (nextStopIndex / totalStops).clamp(0.0, 1.0),
      etaSeconds: etaSeconds,
    );
  }

  const TrackCard.pinned({
    required this.routeLabel,
    required String this.plate,
    required this.targetStopName,
    required this.stopsRemaining,
    required this.progress,
    this.etaSeconds,
  });

  final String routeLabel;

  /// Pinned vehicle plate; null for an unpinned (MaaS riding-leg) card.
  final String? plate;

  /// Alight stop name — 目標站.
  final String targetStopName;

  /// Stops remaining until the alight stop — 還剩 N 站.
  final int stopsRemaining;
  final int? etaSeconds;

  /// 0..1 fraction of the leg completed.
  final double progress;

  @override
  List<Object?> get props => [
    routeLabel,
    plate,
    targetStopName,
    stopsRemaining,
    etaSeconds,
    progress,
  ];
}
