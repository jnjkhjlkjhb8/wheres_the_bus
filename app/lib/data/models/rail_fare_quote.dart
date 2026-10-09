import 'package:equatable/equatable.dart';
import 'package:wheres_the_bus/data/models/fare_type.dart';
import 'package:wheres_the_bus/data/models/thsr_models.dart';
import 'package:wheres_the_bus/data/models/tra_models.dart';

class RailFareQuote extends Equatable {
  const RailFareQuote.tra({
    required List<TraFare> fares,
    required String trainType,
  }) : _traFares = fares,
       _thsrFares = const [],
       _trainType = trainType;

  const RailFareQuote.thsr({required List<ThsrFare> fares})
    : _traFares = const [],
      _thsrFares = fares,
      _trainType = '';

  final List<TraFare> _traFares;
  final List<ThsrFare> _thsrFares;

  /// The train's class, which selects the TRA 車種 tier. Empty for THSR, which
  /// runs one class of train.
  final String _trainType;

  bool get isEmpty => _traFares.isEmpty && _thsrFares.isEmpty;

  /// The fare for [type], or null when the pair prices nothing this rider could
  /// buy. See `ResolvedFare.matched` before labelling the number.
  ResolvedFare? resolve(FareType type) => _thsrFares.isNotEmpty
      ? thsrFareFor(_thsrFares, type)
      : traFareFor(_traFares, _trainType, type);

  @override
  List<Object?> get props => [_traFares, _thsrFares, _trainType];
}
