import 'package:equatable/equatable.dart';

/// Live bike-share availability for one station.
class BikeAvailability extends Equatable {
  const BikeAvailability({
    required this.generalBikes,
    required this.electricBikes,
    required this.returnDocks,
  });

  final int generalBikes;
  final int electricBikes;
  final int returnDocks;

  int get available => generalBikes + electricBikes;

  @override
  List<Object?> get props => [generalBikes, electricBikes, returnDocks];
}

/// Static bike-station facts.
class BikeStationInfo extends Equatable {
  const BikeStationInfo({
    required this.name,
    required this.capacity,
    required this.lat,
    required this.lon,
  });

  final String name;
  final int capacity;
  final double lat;
  final double lon;

  @override
  List<Object?> get props => [name, capacity, lat, lon];
}
