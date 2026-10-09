import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:skeletonizer/skeletonizer.dart';
import 'package:smooth_sheets/smooth_sheets.dart';
import 'package:wheres_the_bus/app/router/app_routes.dart';
import 'package:wheres_the_bus/app/theme/app_text_styles.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/core/errors/app_error.dart';
import 'package:wheres_the_bus/data/models/favorite.dart';
import 'package:wheres_the_bus/data/models/rail_station_board.dart';
import 'package:wheres_the_bus/features/rail/bloc/rail_event.dart';
import 'package:wheres_the_bus/features/rail/bloc/rail_station_board_bloc.dart';
import 'package:wheres_the_bus/features/rail/bloc/rail_station_board_event.dart';
import 'package:wheres_the_bus/features/rail/bloc/rail_station_board_state.dart';
import 'package:wheres_the_bus/features/rail/view/home_rail_query_sheet.dart';
import 'package:wheres_the_bus/features/rail/view/rail_train_screen.dart';
import 'package:wheres_the_bus/features/rail/widgets/rail_query_sheet.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/motion/pressable.dart';
import 'package:wheres_the_bus/shared/rail_system_labels.dart';
import 'package:wheres_the_bus/shared/widgets/app_button.dart';
import 'package:wheres_the_bus/shared/widgets/app_sliding_segment.dart';
import 'package:wheres_the_bus/shared/widgets/bottom_sheet_shell.dart';
import 'package:wheres_the_bus/shared/widgets/error_state_view.dart';
import 'package:wheres_the_bus/shared/widgets/freshness_stamp.dart';
import 'package:wheres_the_bus/shared/widgets/sheet_detail_header.dart';
import 'package:wheres_the_bus/shared/widgets/train_type_chip.dart';

part '../widgets/rail_station_board_widgets.dart';

class RailStationDetailView extends StatelessWidget {
  const RailStationDetailView({
    required this.system,
    required this.stationId,
    required this.name,
    this.bloc,
    super.key,
  });

  final RailSystem system;
  final String stationId;
  final String name;

  final RailStationBoardBloc? bloc;

  @override
  Widget build(BuildContext context) {
    final content = _StationBoard(
      system: system,
      stationId: stationId,
      name: name,
    );
    final existing = bloc;
    if (existing != null) {
      return BlocProvider<RailStationBoardBloc>.value(
        value: existing,
        child: content,
      );
    }
    return BlocProvider(
      create: (_) =>
          RailStationBoardBloc(system: system, stationId: stationId)
            ..add(const RailStationBoardRequested(RailBoardDirection.forward)),
      child: content,
    );
  }
}

class _StationBoard extends StatelessWidget {
  const _StationBoard({
    required this.system,
    required this.stationId,
    required this.name,
  });

  final RailSystem system;
  final String stationId;
  final String name;

  /// 台鐵 labels its two directions 順行/逆行 and 高鐵 labels them 南下/北上.
  /// Each keeps its own operator's wording rather than being forced into one
  /// shared pair — the row's 往<終點站> is what tells the rider which is theirs.
  Map<RailBoardDirection, String> _directions(AppI18n i18n) =>
      system == RailSystem.tra
      ? {
          RailBoardDirection.forward: i18n.railDirectionForward,
          RailBoardDirection.reverse: i18n.railDirectionReverse,
        }
      : {
          RailBoardDirection.forward: i18n.railDirectionSouthbound,
          RailBoardDirection.reverse: i18n.railDirectionNorthbound,
        };

  @override
  Widget build(BuildContext context) {
    final i18n = AppI18n.of(context);
    final cs = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      // Stretch, not start: the segment, the footer button and the empty-state
      // notice all want the sheet's full width. Left to shrink-wrap they hug
      // their content and drift to the left edge.
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SheetDetailHeader(
          title: name,
          subtitle: Text(
            '${system == RailSystem.tra ? i18n.modeTra : i18n.modeThsr}'
            ' · ${i18n.railStationBoard}',
            style: AppTextStyles.bodySmall.copyWith(
              color: cs.onSurfaceVariant,
            ),
          ),
          favorite: Favorite(
            type: FavoriteType.railStation,
            refId: stationId,
            title: name,
            // Which rail system, so opening the 收藏 reaches the right
            // timetable. Stored as the label it displays — see
            // [railSystemLabel] — because `subtitle` is shown on the tile.
            subtitle: railSystemLabel(system),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppTheme.space20,
            AppTheme.space4,
            AppTheme.space20,
            0,
          ),
          child: BlocBuilder<RailStationBoardBloc, RailStationBoardState>(
            buildWhen: (p, n) => p.direction != n.direction,
            builder: (context, state) => AppSlidingSegment<RailBoardDirection>(
              options: _directions(i18n),
              value: state.direction,
              onChanged: (direction) => context
                  .read<RailStationBoardBloc>()
                  .add(RailStationBoardRequested(direction)),
            ),
          ),
        ),
        Flexible(
          child: _BoardBody(system: system),
        ),
        _QueryFooter(system: system, stationId: stationId, name: name),
      ],
    );
  }
}
