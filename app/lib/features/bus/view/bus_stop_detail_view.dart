import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:skeletonizer/skeletonizer.dart';
import 'package:wheres_the_bus/app/router/app_routes.dart';
import 'package:wheres_the_bus/app/theme/app_text_styles.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/core/errors/app_error.dart';
import 'package:wheres_the_bus/data/models/bus_models.dart';
import 'package:wheres_the_bus/data/models/eta_format.dart';
import 'package:wheres_the_bus/data/models/favorite.dart';
import 'package:wheres_the_bus/features/bus/bloc/bus_stop_bloc.dart';
import 'package:wheres_the_bus/features/bus/bloc/bus_stop_event.dart';
import 'package:wheres_the_bus/features/bus/bloc/bus_stop_state.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/motion/app_motion.dart';
import 'package:wheres_the_bus/shared/motion/pressable.dart';
import 'package:wheres_the_bus/shared/widgets/error_state_view.dart';
import 'package:wheres_the_bus/shared/widgets/eta_list_tile.dart';
import 'package:wheres_the_bus/shared/widgets/freshness_stamp.dart';
import 'package:wheres_the_bus/shared/widgets/sheet_detail_header.dart';

part '../widgets/bus_stop_sheet_widgets.dart';
part '../widgets/bus_stop_skeleton_widgets.dart';
part '../widgets/bus_stop_eta_tile_widgets.dart';

class BusStopDetailView extends StatefulWidget {
  const BusStopDetailView({
    required this.stopName,
    this.stopId,
    this.city,
    this.onFocusStation,
    this.bloc,
    super.key,
  });

  final String stopName;
  final String? stopId;
  final String? city;

  /// 選中的成員站座標變更時通知外層移動地圖（首頁用；獨立頁自己有地圖時可傳自身的移動函式）。
  final ValueChanged<LatLng>? onFocusStation;

  /// 呼叫端已 provide 的 [BusStopBloc]（例如同時要畫地圖 marker 的獨立頁）。
  /// 省略時由本 widget 自建並 provide 唯一一份。
  final BusStopBloc? bloc;

  @override
  State<BusStopDetailView> createState() => _BusStopDetailViewState();
}

class _BusStopDetailViewState extends State<BusStopDetailView> {
  /// The bloc currently handed to the provider.
  BusStopBloc? _provided;

  /// Set only when [_provided] is one this view built, and so the only bloc it
  /// may close. Null for as long as the caller keeps supplying one.
  BusStopBloc? _owned;

  @override
  void dispose() {
    unawaited(_owned?.close());
    super.dispose();
  }

  BusStopBloc _bloc() {
    final supplied = widget.bloc;
    if (supplied != null) return _provided = supplied;
    return _provided ??= _owned = BusStopBloc(
      i18n: AppI18n.of(context),
      stopId: widget.stopId,
      city: widget.city,
    );
  }

  Favorite _favorite() => Favorite(
    type: FavoriteType.busStop,
    refId: (widget.stopId?.isNotEmpty ?? false)
        ? widget.stopId!
        : widget.stopName,
    title: widget.stopName,
    subtitle: widget.city ?? '',
  );

  @override
  Widget build(BuildContext context) {
    final content = BlocListener<BusStopBloc, BusStopState>(
      listenWhen: (p, n) => p.selectedStationUid != n.selectedStationUid,
      listener: (context, state) {
        final uid = state.selectedStationUid;
        if (uid == null || widget.onFocusStation == null) return;
        final m = state.members.where((m) => m.stationUid == uid).firstOrNull;
        if (m != null) widget.onFocusStation!(LatLng(m.lat, m.lon));
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SheetDetailHeader(
            title: widget.stopName,
            subtitle: const _StopMeta(),
            favorite: _favorite(),
          ),
          const Flexible(child: _StopSheet()),
        ],
      ),
    );

    return BlocProvider<BusStopBloc>.value(value: _bloc(), child: content);
  }
}
