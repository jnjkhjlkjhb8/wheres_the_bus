import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/data/models/bus_models.dart';
import 'package:wheres_the_bus/features/bus/map/bus_route_overlay.dart';
import 'package:wheres_the_bus/l10n/app_i18n_zh.dart';

void main() {
  final i18n = AppI18nZh();
  const light = AppTheme.lightScheme;
  const dark = AppTheme.darkScheme;

  BusStopModel stop(
    int seq,
    String uid, {
    double lat = 25,
    double lon = 121.5,
  }) => BusStopModel(
    stopUid: uid,
    stopName: '站$seq',
    sequence: seq,
    lat: lat,
    lon: lon,
  );

  BusStopEtaViewModel eta(
    BusStopModel st, {
    int seconds = 300,
    int status = 0,
    int direction = 0,
    List<BusVehiclePosition> vehicles = const [],
  }) => BusStopEtaViewModel(
    stopUid: st.stopUid,
    direction: direction,
    sequence: st.sequence,
    estimateSeconds: seconds,
    nextBusTime: '',
    stopStatus: status,
    vehiclePlates: const [],
    vehicles: vehicles,
  );

  group('marker style', () {
    for (final (name, colors) in [('light', light), ('dark', dark)]) {
      test('quiet and live plates per theme ($name)', () {
        final plate = name == 'dark'
            ? colors.surfaceContainerHigh
            : AppTheme.surfaceCardLight;
        final stopped = markerStyle(
          i18n,
          eta(stop(1, 'a'), seconds: 0, status: 2),
          colors,
        );
        expect(stopped.text, '–');
        expect(stopped.fill, plate);
        expect(stopped.ringWidth, 1.5);
        expect(stopped.height, 30);
        expect(stopped.ring, colors.onSurfaceVariant);

        final unknown = markerStyle(
          i18n,
          eta(stop(1, 'a'), seconds: -1),
          colors,
        );
        expect(unknown.text, '–');
        expect(unknown.height, 30);

        final counting = markerStyle(i18n, eta(stop(1, 'a')), colors);
        expect(counting.fill, plate);
        expect(counting.ringWidth, 2);
        expect(counting.height, 32);
        expect(counting.text, '5');
      });
    }

    for (final (name, colors) in [('light', light), ('dark', dark)]) {
      test('arriving and approaching colours ($name)', () {
        final isDark = name == 'dark';
        final arriving = markerStyle(
          i18n,
          eta(stop(1, 'a'), seconds: 0),
          colors,
        );
        expect(
          arriving.fill,
          isDark ? AppTheme.statusArriving : AppTheme.statusArrivingText,
        );
        expect(
          arriving.content,
          isDark ? AppTheme.inkLight : AppTheme.surfaceCardLight,
        );
        expect(arriving.height, 32);

        final plate = isDark
            ? colors.surfaceContainerHigh
            : AppTheme.surfaceCardLight;
        final approach = isDark
            ? AppTheme.statusApproach
            : AppTheme.etaApproaching;
        final approaching = markerStyle(
          i18n,
          eta(stop(1, 'a'), seconds: 15),
          colors,
        );
        expect(
          approaching.fill,
          Color.alphaBlend(
            approach.withValues(alpha: isDark ? 0.14 : 0.10),
            plate,
          ),
        );
        expect(approaching.ring, approach);
        expect(approaching.ringWidth, 3);
        expect(approaching.height, 34);
      });
    }
  });
}
