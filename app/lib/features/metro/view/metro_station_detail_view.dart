import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:skeletonizer/skeletonizer.dart';
import 'package:wheres_the_bus/app/router/app_routes.dart';
import 'package:wheres_the_bus/app/theme/app_text_styles.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/core/errors/app_error.dart';
import 'package:wheres_the_bus/data/models/arrival_display.dart';
import 'package:wheres_the_bus/data/models/favorite.dart';
import 'package:wheres_the_bus/data/models/metro_map_models.dart';
import 'package:wheres_the_bus/features/metro/bloc/metro_eta_bloc.dart';
import 'package:wheres_the_bus/features/metro/bloc/metro_eta_event.dart';
import 'package:wheres_the_bus/features/metro/bloc/metro_eta_state.dart';
import 'package:wheres_the_bus/features/metro/bloc/mrt_track_bloc.dart';
import 'package:wheres_the_bus/features/metro/bloc/mrt_track_event.dart';
import 'package:wheres_the_bus/features/metro/bloc/mrt_track_state.dart';
import 'package:wheres_the_bus/features/metro/data/metro_line_names.dart';
import 'package:wheres_the_bus/features/metro/view/metro_screen.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/motion/pressable.dart';
import 'package:wheres_the_bus/shared/widgets/alight_track/alight_confirm_bar.dart';
import 'package:wheres_the_bus/shared/widgets/alight_track/alight_track_bell.dart';
import 'package:wheres_the_bus/shared/widgets/bottom_sheet_shell.dart';
import 'package:wheres_the_bus/shared/widgets/eta_list_tile.dart';
import 'package:wheres_the_bus/shared/widgets/freshness_stamp.dart';
import 'package:wheres_the_bus/shared/widgets/line_badge.dart';
import 'package:wheres_the_bus/shared/widgets/sheet_detail_header.dart';
import 'package:wheres_the_bus/shared/widgets/transport_icon.dart';

part '../widgets/metro_schedule_widgets.dart';
part '../widgets/metro_station_detail_widgets.dart';
part '../widgets/metro_status_widgets.dart';

final RegExp _digits = RegExp(r'\d+');

String _lineCode(String id) => id.split('_').first.replaceAll(_digits, '');

String _lineName(AppI18n i18n, String id) =>
    metroLineNames(i18n)[_lineCode(id)] ?? _lineCode(id);

/// Line label for a (possibly interchange) id, e.g. `板南線  文湖線`.
String _stationLineLabel(AppI18n i18n, String id) => id
    .split('_')
    .map((p) => p.replaceAll(_digits, ''))
    .map((code) => metroLineNames(i18n)[code] ?? code)
    .join('  ');

TransportType _getTransportType(String line) {
  switch (line) {
    case 'BL':
      return TransportType.mrtBL;
    case 'R':
      return TransportType.mrtR;
    case 'G':
      return TransportType.mrtG;
    case 'BR':
      return TransportType.mrtBR;
    case 'O':
      return TransportType.mrtO;
    default:
      return TransportType.mrtBL;
  }
}

class MetroStationDetailView extends StatelessWidget {
  const MetroStationDetailView({
    required this.system,
    required this.stationId,
    required this.name,
    this.onClose,
    super.key,
  });

  final String system;
  final String stationId;
  final String name;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final sheet = BlocProvider(
      create: (_) => MetroEtaBloc()..add(LoadMetroEta(system, stationId)),
      child: _StationDetailSheet(
        system: system,
        station: MetroMapStation(id: stationId, name: name, x: 0, y: 0),
        onClose: onClose,
      ),
    );
    if (onClose != null) return sheet;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SheetDragHandle(),
        Flexible(child: sheet),
      ],
    );
  }
}
