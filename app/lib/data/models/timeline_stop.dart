import 'package:equatable/equatable.dart';

enum TimelineStopState { none, approaching, arriving }

class TimelineStop extends Equatable {
  const TimelineStop({
    required this.uid,
    required this.name,
    this.primaryTime,
    this.primaryLabel,
    this.secondaryTime,
    this.secondaryLabel,
    this.state = TimelineStopState.none,
    this.active = false,
    this.lat,
    this.lon,
    this.isBuffer = false,
    this.fareSection,
    this.isLiveEta = false,
    this.etaMinutes,
    this.serviceEnded = false,
    this.plate = '',
  });

  final String uid;
  final String name;
  final String? primaryTime;
  final String? primaryLabel;
  final String? secondaryTime;
  final String? secondaryLabel;
  final TimelineStopState state;
  final bool active;
  final double? lat;
  final double? lon;
  final bool isBuffer;

  final int? fareSection;

  /// Whether [primaryTime] is a live countdown rather than a scheduled
  /// departure clock or a service-state word. The string alone can't say — see
  /// `busStopLabelIsLive` — and the two must not be styled the same.
  final bool isLiveEta;

  /// Whether this stop has no more service today (stopStatus 3 / 4). Carried
  /// as a flag rather than re-read from [primaryTime]: that label is localized,
  /// so matching on its words would break in every other locale.
  final bool serviceEnded;

  final int? etaMinutes;

  /// Plate of the vehicle this stop's estimate describes, uppercase-trimmed by
  /// the server. Empty when TDX sent none — the vehicle marker then prints no
  /// plate rather than guessing which bus it is.
  final String plate;

  @override
  List<Object?> get props => [
    uid,
    name,
    primaryTime,
    secondaryTime,
    state,
    active,
    isBuffer,
    fareSection,
    isLiveEta,
    etaMinutes,
    plate,
  ];
}
