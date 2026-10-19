import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/data/models/near_models.dart';
import 'package:wheres_the_bus/features/home/widgets/home_marker_style.dart';
import 'package:wheres_the_bus/shared/map/marker_factory.dart';
import 'package:wheres_the_bus/shared/widgets/transport_icon.dart';

NearStationViewModel _station(NearStationType type, [String id = 'x']) =>
    NearStationViewModel(
      type: type,
      stationId: id,
      stationName: 'name',
      lat: 25,
      lon: 121,
      walkingMinutes: 1,
      distanceMeters: 10,
    );

NearStationViewModel _mrt(String id) => _station(NearStationType.mrt, id);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => MapMarkers.configure(devicePixelRatio: 3));

  group('markerStyleForZoom', () {
    test('switches to icons from zoom 15.5', () {
      expect(markerStyleForZoom(15.5), MarkerStyle.icon);
      expect(markerStyleForZoom(21), MarkerStyle.icon);
      expect(markerStyleForZoom(15.49), MarkerStyle.largeDot);
    });

    test('uses large dots from zoom 13 up to the icon band', () {
      expect(markerStyleForZoom(13), MarkerStyle.largeDot);
      expect(markerStyleForZoom(14.2), MarkerStyle.largeDot);
      expect(markerStyleForZoom(12.99), MarkerStyle.smallDot);
    });

    test('uses small dots when zoomed far out', () {
      expect(markerStyleForZoom(3), MarkerStyle.smallDot);
      expect(markerStyleForZoom(0), MarkerStyle.smallDot);
    });

    test('exposes the thresholds and sizes the map relies on', () {
      expect(kIconZoomThreshold, 15.5);
      expect(kLargeDotZoomThreshold, 13);
      expect(kMapMarkerLimit, 60);
      expect(kIconMarkerSize, 24);
      expect(kHighlightIconMarkerSize, 44);
    });
  });

  group('dotMarkerSize', () {
    test('only the mid band gets the large dot', () {
      expect(dotMarkerSize(MarkerStyle.largeDot), 10);
      expect(dotMarkerSize(MarkerStyle.smallDot), 7);
      expect(dotMarkerSize(MarkerStyle.icon), 7);
      expect(kLargeDotSize, 10);
      expect(kSmallDotSize, 7);
    });
  });

  group('mrtColor', () {
    test('maps each line prefix to its colour', () {
      expect(mrtColor('BL15'), AppTheme.mrtBL);
      expect(mrtColor('R10'), AppTheme.mrtR);
      expect(mrtColor('G12'), AppTheme.mrtG);
      expect(mrtColor('O07'), AppTheme.mrtO);
      expect(mrtColor('BR09'), AppTheme.mrtBR);
      expect(mrtColor('Y11'), AppTheme.mrtY);
      expect(mrtColor('C03'), AppTheme.mrtKG);
    });

    test('reads the prefix up to the first underscore or digit', () {
      expect(mrtColor('R_10'), AppTheme.mrtR);
      expect(mrtColor('br_3'), AppTheme.mrtBR);
      expect(mrtColor('g'), AppTheme.mrtG);
      expect(mrtColor('o9x'), AppTheme.mrtO);
    });

    test('falls back to the blue line for unknown prefixes', () {
      expect(mrtColor('ZZ01'), AppTheme.mrtBL);
      expect(mrtColor('K01'), AppTheme.mrtBL);
      expect(mrtColor(''), AppTheme.mrtBL);
    });

    test('the line colours are all different', () {
      final colours = {
        for (final id in ['BL1', 'R1', 'G1', 'O1', 'BR1', 'Y1', 'C1'])
          mrtColor(id),
      };
      expect(colours, hasLength(7));
    });
  });

  group('iconAsset', () {
    test('bus, bike and rail have fixed artwork', () {
      expect(iconAsset(_station(NearStationType.bus)), 'assets/marker/Bus.svg');
      expect(
        iconAsset(_station(NearStationType.bike)),
        'assets/marker/bike.svg',
      );
      expect(iconAsset(_station(NearStationType.tra)), 'assets/rails/TRA.svg');
      expect(
        iconAsset(_station(NearStationType.thsr)),
        'assets/rails/THSR.svg',
      );
    });

    test('Taipei metro prefixes resolve to their line icon', () {
      for (final code in ['BL', 'BR', 'G', 'O', 'R', 'Y', 'K']) {
        expect(iconAsset(_mrt('${code}12')), 'assets/mrt/TRTC/$code.svg');
      }
      expect(iconAsset(_mrt('bl_07')), 'assets/mrt/TRTC/BL.svg');
      expect(iconAsset(_mrt('br03')), 'assets/mrt/TRTC/BR.svg');
    });

    test('metro prefixes without bundled artwork have no icon', () {
      expect(iconAsset(_mrt('C03')), isNull);
      expect(iconAsset(_mrt('ZZ01')), isNull);
      expect(iconAsset(_mrt('')), isNull);
    });
  });

  group('nearbyIconType', () {
    test('non-metro stations keep their own transport type', () {
      expect(nearbyIconType(_station(NearStationType.bus)), TransportType.bus);
      expect(
        nearbyIconType(_station(NearStationType.bike)),
        TransportType.bike,
      );
      expect(nearbyIconType(_station(NearStationType.tra)), TransportType.tra);
      expect(
        nearbyIconType(_station(NearStationType.thsr)),
        TransportType.thsr,
      );
    });

    test('metro stations map to their line type', () {
      expect(nearbyIconType(_mrt('BL15')), TransportType.mrtBL);
      expect(nearbyIconType(_mrt('R10')), TransportType.mrtR);
      expect(nearbyIconType(_mrt('G12')), TransportType.mrtG);
      expect(nearbyIconType(_mrt('O07')), TransportType.mrtO);
      expect(nearbyIconType(_mrt('BR09')), TransportType.mrtBR);
      expect(nearbyIconType(_mrt('Y11')), TransportType.mrtY);
      expect(nearbyIconType(_mrt('C03')), TransportType.mrtKG);
      expect(nearbyIconType(_mrt('g_4')), TransportType.mrtG);
    });

    test('unknown metro prefixes fall back to the blue line', () {
      expect(nearbyIconType(_mrt('ZZ01')), TransportType.mrtBL);
      expect(nearbyIconType(_mrt('K01')), TransportType.mrtBL);
    });
  });

  group('markerIcon', () {
    Future<ui.Image> decode(BitmapDescriptor icon) async {
      final codec = await ui.instantiateImageCodec(
        (icon as BytesMapBitmap).byteData,
      );
      return (await codec.getNextFrame()).image;
    }

    Future<Color> centre(ui.Image image) async {
      final data = (await image.toByteData())!;
      final bytes = Uint8List.view(data.buffer);
      final offset = ((image.height ~/ 2) * image.width + image.width ~/ 2) * 4;
      return Color.fromARGB(
        bytes[offset + 3],
        bytes[offset],
        bytes[offset + 1],
        bytes[offset + 2],
      );
    }

    Future<void> expectDot(
      NearStationViewModel station,
      MarkerStyle style,
      Color colour,
      int px, {
      bool highlighted = false,
    }) async {
      final image = await decode(
        await markerIcon(station, style, highlighted: highlighted),
      );
      expect(image.width, px);
      expect(image.height, px);
      expect(await centre(image), colour);
      image.dispose();
    }

    test('bus, bike and rail stations are colour-coded dots', () async {
      await expectDot(
        _station(NearStationType.bus),
        MarkerStyle.smallDot,
        AppTheme.markerBus,
        21,
      );
      await expectDot(
        _station(NearStationType.bike),
        MarkerStyle.smallDot,
        AppTheme.markerBike,
        21,
      );
      await expectDot(
        _station(NearStationType.tra),
        MarkerStyle.smallDot,
        AppTheme.markerRail,
        21,
      );
      await expectDot(
        _station(NearStationType.thsr),
        MarkerStyle.smallDot,
        AppTheme.markerRail,
        21,
      );
    });

    test('the mid band draws larger dots', () async {
      await expectDot(
        _station(NearStationType.bus),
        MarkerStyle.largeDot,
        AppTheme.markerBus,
        30,
      );
    });

    test('metro dots take the line colour', () async {
      await expectDot(
        _mrt('R10'),
        MarkerStyle.largeDot,
        AppTheme.mrtR,
        30,
      );
      await expectDot(
        _mrt('G03'),
        MarkerStyle.smallDot,
        AppTheme.mrtG,
        21,
      );
    });

    test('icon style draws the bundled artwork at icon size', () async {
      final image = await decode(
        await markerIcon(_station(NearStationType.bus), MarkerStyle.icon),
      );
      expect(image.width, 72);
      expect(image.height, 72);
      image.dispose();
    });

    test('a highlighted station gets the big icon whatever the zoom', () async {
      for (final style in MarkerStyle.values) {
        final image = await decode(
          await markerIcon(
            _station(NearStationType.bus),
            style,
            highlighted: true,
          ),
        );
        expect(image.width, 132, reason: '$style');
        image.dispose();
      }
    });

    test('metro lines without artwork fall back to a coloured dot', () async {
      await expectDot(_mrt('C03'), MarkerStyle.icon, AppTheme.mrtKG, 72);
      await expectDot(
        _mrt('C03'),
        MarkerStyle.smallDot,
        AppTheme.mrtKG,
        132,
        highlighted: true,
      );
    });
  });
}
