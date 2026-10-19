import 'package:flutter/material.dart';
import 'package:wheres_the_bus/data/models/near_models.dart';
import 'package:wheres_the_bus/features/bike/view/bike_station_detail_view.dart';
import 'package:wheres_the_bus/features/bus/bloc/bus_stop_bloc.dart';
import 'package:wheres_the_bus/features/bus/view/bus_stop_detail_view.dart';
import 'package:wheres_the_bus/features/metro/view/metro_station_detail_view.dart';
import 'package:wheres_the_bus/features/rail/bloc/rail_event.dart';
import 'package:wheres_the_bus/features/rail/view/rail_station_detail_view.dart';

Widget stationDetailPage(
  NearStationViewModel station, {
  BusStopBloc? bloc,
}) => _stationDetailContent(station, bloc);

Widget _stationDetailContent(
  NearStationViewModel station,
  BusStopBloc? busStopBloc,
) {
  return switch (station.type) {
    NearStationType.bus => BusStopDetailView(
      stopName: station.stationName,
      stopId: station.stationId,
      bloc: busStopBloc,
      // onFocusStation 省略：選中的成員站已由地圖上的膠囊翻墨色回答，
      // 再自動平移會在使用者捲動清單時把地圖抽走。
    ),
    NearStationType.bike => BikeStationDetailView(
      stationUid: station.stationId,
      name: station.stationName,
      lat: station.lat,
      lon: station.lon,
    ),
    // TRTC 為固定值：NearStationViewModel 未帶捷運系統欄位，
    // 且目前 app 內僅支援台北捷運 (TRTC)；等有第二個系統再擴充 model。
    NearStationType.mrt => MetroStationDetailView(
      system: 'TRTC',
      stationId: station.stationId,
      name: station.stationName,
    ),
    NearStationType.tra => RailStationDetailView(
      system: RailSystem.tra,
      stationId: station.stationId,
      name: station.stationName,
    ),
    NearStationType.thsr => RailStationDetailView(
      system: RailSystem.thsr,
      stationId: station.stationId,
      name: station.stationName,
    ),
  };
}
