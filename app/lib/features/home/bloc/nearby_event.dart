import 'package:equatable/equatable.dart';
import 'package:wheres_the_bus/data/models/near_models.dart';

sealed class NearbyEvent extends Equatable {
  const NearbyEvent();

  @override
  List<Object?> get props => [];
}

final class NearbyRequested extends NearbyEvent {
  const NearbyRequested({required this.radius, this.lat, this.lon});

  final int radius;
  final double? lat;
  final double? lon;

  @override
  List<Object?> get props => [radius, lat, lon];
}

/// Re-sends the most recent [NearbyRequested] query verbatim — including a
/// failed dragged-viewport query — rather than falling back to device GPS.
final class NearbyRetried extends NearbyEvent {
  const NearbyRetried();
}

/// A response off the shared query stream. Internal: the bloc raises it from
/// the stream subscription because a state emitter is only valid inside an
/// event handler.
final class NearbyStationsReceived extends NearbyEvent {
  const NearbyStationsReceived(this.stations);

  final List<NearStationViewModel> stations;

  @override
  List<Object?> get props => [stations];
}

/// The shared query stream broke. Internal — see [NearbyStationsReceived].
final class NearbyStreamFailed extends NearbyEvent {
  const NearbyStreamFailed(this.error);

  final Object error;

  @override
  List<Object?> get props => [error];
}
