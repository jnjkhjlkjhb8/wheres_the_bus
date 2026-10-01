import 'package:wheres_the_bus/core/grpc/grpc_client.dart';
import 'package:wheres_the_bus/data/decoders/thsr_decoder.dart';
import 'package:wheres_the_bus/data/generated/thsr.pbgrpc.dart';
import 'package:wheres_the_bus/data/models/rail_station_board.dart';
import 'package:wheres_the_bus/data/models/thsr_models.dart';
import 'package:wheres_the_bus/data/repositories/offline_cache.dart';

class ThsrRepository {
  ThsrRepository({
    Thsr_timetable_serviceClient? timetableClient,
    Thsr_Detain_serviceClient? detainClient,
  }) : _timetableClient = timetableClient,
       _detainClient = detainClient;

  static final ThsrRepository instance = ThsrRepository();

  final Thsr_timetable_serviceClient? _timetableClient;
  Thsr_timetable_serviceClient get _grpc =>
      _timetableClient ?? GrpcClient.instance.thsr;

  final Thsr_Detain_serviceClient? _detainClient;
  Thsr_Detain_serviceClient get _detain =>
      _detainClient ?? GrpcClient.instance.thsrDetain;

  Future<List<ThsrFare>> fares(String date, String originId, String destId) =>
      offlineCached(
        key: 's:thsr:fare:$originId:$destId',
        fetch: () => _grpc.fare(
          Ask_Thsr(
            date: date,
            originStationId: originId,
            destinationStationId: destId,
          ),
        ),
        parse: thsa_fares.fromBuffer,
        decode: ThsrDecoder.instance.decodeFares,
      );

  Future<List<ThsrTimetableItem>> timetable(
    String date,
    String originId,
    String destId,
  ) => offlineCached(
    key: 'd:$date:thsr:tt:$originId:$destId',
    fetch: () => _grpc.timetable(
      Ask_Thsr(
        date: date,
        originStationId: originId,
        destinationStationId: destId,
      ),
    ),
    parse: thsr_timetables.fromBuffer,
    decode: ThsrDecoder.instance.decodeTimetable,
  );

  /// The next departures from one station in one direction. See
  /// `TraRepository.stationBoard` for why [after] comes from the caller's clock
  /// and why the offline key leaves it out.
  Future<List<RailStationDeparture>> stationBoard({
    required String stationId,
    required String date,
    required String after,
    required RailBoardDirection direction,
  }) => offlineCached(
    key: 'd:$date:thsr:board:$stationId:${direction.wire}',
    fetch: () => _grpc.station_board(
      thsr_ask_station_board(
        stationId: stationId,
        date: date,
        after: after,
        direction: direction.wire,
      ),
    ),
    parse: thsr_station_board.fromBuffer,
    decode: ThsrDecoder.instance.decodeStationBoard,
  );

  Future<List<ThsrStopTime>> stops(String date, String trainNo) =>
      offlineCached(
        key: 'd:$date:thsr:stops:$trainNo',
        fetch: () =>
            _detain.stops(thsr_ask_detain(date: date, trainno: trainNo)),
        parse: thsr_stoptimes.fromBuffer,
        decode: ThsrDecoder.instance.decodeStopTimes,
      );
}
