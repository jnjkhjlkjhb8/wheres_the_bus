import 'package:flutter/material.dart';
import 'package:google_maps_flutter_platform_interface/google_maps_flutter_platform_interface.dart';

class FakeMapPlatform extends GoogleMapsFlutterPlatform {
  final cameraUpdates = <CameraUpdate>[];
  final initialPositions = <CameraPosition>[];
  final markerUpdates = <MarkerUpdates>[];
  final created = <int>{};
  final disposed = <int>{};
  MapObjects objects = const MapObjects();
  MapConfiguration configuration = const MapConfiguration();

  @override
  Widget buildViewWithConfiguration(
    int creationId,
    void Function(int) onPlatformViewCreated, {
    required MapWidgetConfiguration widgetConfiguration,
    MapConfiguration mapConfiguration = const MapConfiguration(),
    MapObjects mapObjects = const MapObjects(),
  }) {
    objects = mapObjects;
    configuration = mapConfiguration;
    if (created.add(creationId)) {
      initialPositions.add(widgetConfiguration.initialCameraPosition);
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => onPlatformViewCreated(creationId),
      );
    }
    return const ColoredBox(color: Colors.white);
  }

  @override
  Future<void> init(int mapId) async {}
  @override
  void dispose({required int mapId}) => disposed.add(mapId);
  @override
  Future<void> animateCamera(CameraUpdate update, {required int mapId}) async {
    cameraUpdates.add(update);
  }

  @override
  Future<void> moveCamera(CameraUpdate update, {required int mapId}) async {
    cameraUpdates.add(update);
  }

  @override
  Future<double> getZoomLevel({required int mapId}) async => 15;

  @override
  Future<LatLngBounds> getVisibleRegion({required int mapId}) async =>
      LatLngBounds(
        southwest: const LatLng(24.995, 120.995),
        northeast: const LatLng(25.005, 121.005),
      );

  @override
  Future<void> updateMapConfiguration(
    MapConfiguration update, {
    required int mapId,
  }) async {}
  @override
  Future<void> updateMarkers(
    MarkerUpdates updates, {
    required int mapId,
  }) async {
    markerUpdates.add(updates);
  }

  @override
  Future<void> updatePolygons(
    PolygonUpdates updates, {
    required int mapId,
  }) async {}
  @override
  Future<void> updatePolylines(
    PolylineUpdates updates, {
    required int mapId,
  }) async {}
  @override
  Future<void> updateCircles(
    CircleUpdates updates, {
    required int mapId,
  }) async {}
  @override
  Future<void> updateHeatmaps(
    HeatmapUpdates updates, {
    required int mapId,
  }) async {}
  @override
  Future<void> updateTileOverlays({
    required Set<TileOverlay> newTileOverlays,
    required int mapId,
  }) async {}
  @override
  Future<void> updateClusterManagers(
    ClusterManagerUpdates updates, {
    required int mapId,
  }) async {}
  @override
  Future<void> updateGroundOverlays(
    GroundOverlayUpdates updates, {
    required int mapId,
  }) async {}

  @override
  Stream<CameraMoveStartedEvent> onCameraMoveStarted({required int mapId}) =>
      const Stream.empty();

  @override
  Stream<CameraMoveEvent> onCameraMove({required int mapId}) =>
      const Stream.empty();

  @override
  Stream<CameraIdleEvent> onCameraIdle({required int mapId}) =>
      const Stream.empty();

  @override
  Stream<MarkerTapEvent> onMarkerTap({required int mapId}) =>
      const Stream.empty();

  @override
  Stream<MarkerDragStartEvent> onMarkerDragStart({required int mapId}) =>
      const Stream.empty();

  @override
  Stream<MarkerDragEvent> onMarkerDrag({required int mapId}) =>
      const Stream.empty();

  @override
  Stream<MarkerDragEndEvent> onMarkerDragEnd({required int mapId}) =>
      const Stream.empty();

  @override
  Stream<InfoWindowTapEvent> onInfoWindowTap({required int mapId}) =>
      const Stream.empty();

  @override
  Stream<PolylineTapEvent> onPolylineTap({required int mapId}) =>
      const Stream.empty();

  @override
  Stream<PolygonTapEvent> onPolygonTap({required int mapId}) =>
      const Stream.empty();

  @override
  Stream<CircleTapEvent> onCircleTap({required int mapId}) =>
      const Stream.empty();

  @override
  Stream<MapTapEvent> onTap({required int mapId}) => const Stream.empty();

  @override
  Stream<MapLongPressEvent> onLongPress({required int mapId}) =>
      const Stream.empty();

  @override
  Stream<ClusterTapEvent> onClusterTap({required int mapId}) =>
      const Stream.empty();
}
