import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:skeletonizer/skeletonizer.dart';
import 'package:wheres_the_bus/app/router/app_routes.dart';
import 'package:wheres_the_bus/app/theme/app_text_styles.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/core/errors/app_error.dart';
import 'package:wheres_the_bus/data/models/favorite.dart';
import 'package:wheres_the_bus/features/bike/bloc/bike_station_bloc.dart';
import 'package:wheres_the_bus/features/bike/bloc/bike_station_state.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/widgets/app_button.dart';
import 'package:wheres_the_bus/shared/widgets/availability_gauge.dart';
import 'package:wheres_the_bus/shared/widgets/freshness_stamp.dart';
import 'package:wheres_the_bus/shared/widgets/sheet_detail_header.dart';
import 'package:wheres_the_bus/shared/widgets/state_cards.dart';

class BikeStationDetailView extends StatelessWidget {
  const BikeStationDetailView({
    required this.stationUid,
    this.bloc,
    this.name,
    this.lat,
    this.lon,
    super.key,
  });

  final String stationUid;

  /// A [BikeStationBloc] the caller already owns (the standalone screen also
  /// draws the map from it). Omitted, this widget creates and provides the
  /// only one; passing it in avoids a second static fetch and live stream.
  final BikeStationBloc? bloc;

  final String? name;
  final double? lat;
  final double? lon;

  @override
  Widget build(BuildContext context) {
    final content = BlocBuilder<BikeStationBloc, BikeStationState>(
      buildWhen: (p, n) =>
          p.name != n.name ||
          p.capacity != n.capacity ||
          p.updatedAt != n.updatedAt,
      builder: (context, state) {
        final title = state.name.isNotEmpty ? state.name : stationUid;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SheetDetailHeader(
              title: title,
              subtitle: _StationMeta(
                capacity: state.capacity,
                updatedAt: state.updatedAt,
              ),
              favorite: Favorite(
                type: FavoriteType.bikeStation,
                refId: stationUid,
                title: title,
              ),
            ),
            const Flexible(child: _StationSheet()),
          ],
        );
      },
    );
    final existing = bloc;
    if (existing != null) {
      return BlocProvider<BikeStationBloc>.value(
        value: existing,
        child: content,
      );
    }
    return BlocProvider(
      create: (_) => BikeStationBloc(
        stationUid: stationUid,
        name: name,
        lat: lat,
        lon: lon,
      ),
      child: content,
    );
  }
}

/// Header subtitle: the station's size and how fresh its counts are — the two
/// facts that turn a bare number into a reading. Capacity was fetched but
/// never shown before, and a live-streamed count carried no timestamp at all.
class _StationMeta extends StatelessWidget {
  const _StationMeta({required this.capacity, required this.updatedAt});

  final int capacity;
  final DateTime? updatedAt;

  @override
  Widget build(BuildContext context) {
    if (capacity <= 0 && updatedAt == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: FreshnessStamp(
        at: updatedAt,
        leading: capacity > 0
            ? AppI18n.of(context).bikeDockCount(capacity)
            : null,
      ),
    );
  }
}

class _StationSheet extends StatelessWidget {
  const _StationSheet();

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<BikeStationBloc, BikeStationState>(
      builder: (context, state) {
        // Column, not ListView: the sheet measures its own content height and
        // an unbounded scrollable inside it has nothing to measure against.
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(
            AppTheme.space16,
            AppTheme.space4,
            AppTheme.space16,
            AppTheme.space32,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (state.loading) ...const [
                // The loaded gauge with stand-in counts: same geometry, so
                // the real numbers land where the bones were.
                Skeletonizer(
                  child: AvailabilityGauge(
                    available: 12,
                    docks: 8,
                    capacity: 20,
                    generalBikes: 9,
                    electricBikes: 3,
                  ),
                ),
              ] else if (state.error != null) ...[
                // Static station-info fetch failed outright: no name/capacity,
                // nothing meaningful to show under it.
                ErrorStateCard(message: state.error!),
              ] else ...[
                if (state.liveError != null && !state.hasLiveData)
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppTheme.space12),
                    child: _LiveDataNotice(error: state.liveError!),
                  ),
                AvailabilityGauge(
                  available: state.available,
                  docks: state.returnDocks,
                  capacity: state.capacity,
                  generalBikes: state.generalBikes,
                  electricBikes: state.electricBikes,
                  hasLiveData: state.hasLiveData,
                ),
                if (state.lat != 0 || state.lon != 0) ...[
                  const SizedBox(height: AppTheme.space20),
                  _WalkThereButton(
                    lat: state.lat,
                    lon: state.lon,
                    name: state.name,
                  ),
                ],
              ],
            ],
          ),
        );
      },
    );
  }
}

class _WalkThereButton extends StatelessWidget {
  const _WalkThereButton({
    required this.lat,
    required this.lon,
    required this.name,
  });

  final double lat;
  final double lon;
  final String name;

  @override
  Widget build(BuildContext context) {
    return AppButton(
      label: AppI18n.of(context).bikePlanRoute,
      icon: Icons.directions_rounded,
      onPressed: () => unawaited(
        context.push(
          AppRoutes.goToDestination(
            // The station UID is never a usable label; fall back to a coarse
            // one rather than pushing an empty destination field.
            name: name.isNotEmpty
                ? name
                : AppI18n.of(context).bikeStationFallbackName,
            lat: lat,
            lon: lon,
          ),
        ),
      ),
    );
  }
}

/// Compact inline notice for a live availability stream that never came up —
/// deliberately smaller than [ErrorStateCard] since the station's static info
/// and (stale) counts are still shown underneath it.
class _LiveDataNotice extends StatelessWidget {
  const _LiveDataNotice({required this.error});

  final AppError error;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        Icon(Icons.cloud_off_rounded, size: 16, color: cs.error),
        const SizedBox(width: AppTheme.space6),
        Expanded(
          child: Text(
            error.titleOf(AppI18n.of(context)),
            style: AppTextStyles.bodySmall.copyWith(color: cs.error),
          ),
        ),
      ],
    );
  }
}
