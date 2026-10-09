import 'package:equatable/equatable.dart';

class RailTimetableView extends Equatable {
  const RailTimetableView({
    required this.trainNo,
    required this.trainType,
    required this.originName,
    required this.destinationName,
    required this.departureTime,
    required this.arrivalTime,
    required this.travelTime,
  });

  final String trainNo;
  final String trainType;
  final String originName;
  final String destinationName;
  final String departureTime;
  final String arrivalTime;
  final String travelTime;

  @override
  List<Object?> get props => [
    trainNo,
    trainType,
    originName,
    destinationName,
    departureTime,
    arrivalTime,
    travelTime,
  ];
}
