import 'package:wheres_the_bus/data/tracking/journey_models.dart';

abstract class JourneySessionEvent {
  const JourneySessionEvent();
}

class JourneyStarted extends JourneySessionEvent {
  const JourneyStarted({
    required this.legs,
    this.trackOnly = false,
    this.plate,
    this.leadStops = 1,
  });
  final List<JourneyLeg> legs;

  /// The rider's 提前站數. Decides when the tracking card's bar turns amber —
  /// the same threshold the arrival reminder fires on, so one number defines
  /// "close" for both.
  final int leadStops;

  /// A standalone arrival-countdown session (bus stop / rail departure
  /// tracking): the session never rides and ends itself once the tracked
  /// vehicle has arrived and left.
  final bool trackOnly;

  /// The pinned vehicle's plate, display/reminder metadata only — the ETA
  /// stream stays next-bus-per-stop and is never filtered by plate.
  final String? plate;
}

class BoardConfirmed extends JourneySessionEvent {
  const BoardConfirmed();
}

class AlightConfirmed extends JourneySessionEvent {
  const AlightConfirmed();
}

class JourneyCancelled extends JourneySessionEvent {
  const JourneyCancelled({this.userInitiated = false});

  final bool userInitiated;
}

class EtaTicked extends JourneySessionEvent {
  const EtaTicked(this.eta, {required this.generation});
  final Duration? eta;
  final int generation;
}

/// Internal: riding-mode progress advanced to [nextStopIndex]. See
/// [EtaTicked.generation].
class ProgressTicked extends JourneySessionEvent {
  const ProgressTicked(this.nextStopIndex, {required this.generation});
  final int nextStopIndex;
  final int generation;
}

/// Internal: the pinned vehicle's live stop-distance from the alight stop,
/// recomputed from a fresh route-ETA frame (null = not yet resolvable). See
/// [EtaTicked.generation].
class PinnedStopsUpdated extends JourneySessionEvent {
  const PinnedStopsUpdated(this.stopsRemaining, {required this.generation});
  final int? stopsRemaining;
  final int generation;
}

/// Internal: a fresh rail tracking frame (schedule + live TRA delay derived).
/// Carries everything the rail riding card needs. See [EtaTicked.generation].
class RailTrackTicked extends JourneySessionEvent {
  const RailTrackTicked({
    required this.eta,
    required this.remainingStops,
    required this.progress,
    required this.nextStop,
    required this.aboard,
    required this.etaToBoard,
    required this.delay,
    required this.generation,
  });
  final Duration eta;
  final int remainingStops;
  final double progress;
  final String nextStop;

  /// Whether the train has reached the boarding stop yet. False means the
  /// rider is still on the platform and the card counts minutes to departure
  /// rather than stops to the alight.
  final bool aboard;
  final Duration etaToBoard;

  /// Live delay against the timetable. Zero on THSR, which has no live feed.
  final Duration delay;
  final int generation;
}
