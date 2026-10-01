part of 'rail_train_screen.dart';

class _InfoTab extends StatelessWidget {
  const _InfoTab({
    required this.type,
    required this.trainNo,
    required this.stops,
    required this.fullFare,
    required this.userFare,
    this.userOrigin,
    this.userDest,
    this.marks = const [],
    this.remark = '',
  });

  final String type;
  final String trainNo;
  final List<RailTrainStop> stops;

  /// Amenities this train carries, shown here in the operator's own artwork
  /// with labels — the timetable list only had room for muted silhouettes.
  final List<RailServiceMark> marks;

  /// Operator free text about this train, e.g. "本車次不停靠苗栗、彰化、雲林
  /// 站". Variable length, so it belongs here rather than in a list row where
  /// it would break the alignment the timetable depends on.
  final String remark;

  /// Fare for the train's own full run (its first stop to its last),
  /// best-effort and possibly null.
  final RailFareQuote? fullFare;

  final RailFareQuote? userFare;
  final String? userOrigin;
  final String? userDest;

  static const TextStyle _labelStyle = AppTextStyles.bodyLarge;
  static const TextStyle _valueStyle = AppTextStyles.heading2;

  RailTrainStop? _findStop(String name) {
    for (final s in stops) {
      if (sameStation(s.name, name)) return s;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    final userOriginStop = userOrigin != null ? _findStop(userOrigin!) : null;
    final userDestStop = userDest != null ? _findStop(userDest!) : null;
    final showUserSegment = userOriginStop != null && userDestStop != null;
    final isFullRun =
        !showUserSegment ||
        (userOriginStop.name == stops.first.name &&
            userDestStop.name == stops.last.name);

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTheme.space16,
        vertical: AppTheme.space16,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: AppTheme.space16,
        children: [
          _buildTrainInfo(
            AppI18n.of(context),
            cs,
            userOriginStop,
            userDestStop,
            showUserSegment,
            isFullRun,
          ),
          if (userFare != null || fullFare != null)
            _buildFare(
              cs,
              userOriginStop,
              userDestStop,
              showUserSegment,
              isFullRun,
            ),
          if (remark.trim().isNotEmpty) ...[
            Divider(height: 1, thickness: 0.5, color: cs.outlineVariant),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 5,
              children: [
                Text(
                  AppI18n.of(context).commonNote,
                  style: _labelStyle.copyWith(color: cs.onSurfaceVariant),
                ),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 5,
                  children: [
                    if (marks.isNotEmpty) ...[
                      RailServiceMarkChips(marks: marks),
                    ],
                    Expanded(
                      child: Text(
                        remark.trim(),
                        style: AppTextStyles.bodyRegular.copyWith(
                          color: cs.onSurface,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildTrainInfo(
    AppI18n i18n,
    ColorScheme cs,
    RailTrainStop? userOriginStop,
    RailTrainStop? userDestStop,
    bool showUserSegment,
    bool isFullRun,
  ) {
    final runOrigin = stops.first;
    final runDest = stops.last;

    // Product decision: the user's own segment is the primary information,
    // the train's full run is secondary context — so it, not the run, is
    // the headline once we have it.
    final headlineOrigin = showUserSegment ? userOriginStop! : runOrigin;
    final headlineDest = showUserSegment ? userDestStop! : runDest;

    final departTime = hhmm(
      headlineOrigin.depart.isNotEmpty
          ? headlineOrigin.depart
          : headlineOrigin.arrive,
    );
    final arriveTime = hhmm(
      headlineDest.arrive.isNotEmpty
          ? headlineDest.arrive
          : headlineDest.depart,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: AppTheme.space10,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: AppTheme.space4,
          children: [
            Text(
              i18n.railTrainAndType,
              style: _labelStyle.copyWith(color: cs.onSurfaceVariant),
            ),
            Row(
              children: [
                Text(trainNo, style: _valueStyle),
                const SizedBox(width: AppTheme.space10),
                TrainTypeChip(type: type),
              ],
            ),
          ],
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 5,
          children: [
            Text(
              i18n.railEndpoints,
              style: _labelStyle.copyWith(color: cs.onSurfaceVariant),
            ),
            Row(
              spacing: AppTheme.space6,
              children: [
                Text(headlineOrigin.name, style: _valueStyle),
                const Text('→', style: _valueStyle),
                Text(headlineDest.name, style: _valueStyle),
              ],
            ),
            // Secondary context, only shown when it actually differs from
            // the headline above — the train's full route, not the user's
            // slice of it.
            if (showUserSegment && !isFullRun)
              Text(
                i18n.railFullRun(runOrigin.name, runDest.name),
                style: AppTextStyles.bodySmall.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
          ],
        ),
        Divider(height: 1, thickness: 0.5, color: cs.outlineVariant),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 5,
          children: [
            Text(
              i18n.railRunningTime,
              style: _labelStyle.copyWith(color: cs.onSurfaceVariant),
            ),
            Row(
              spacing: AppTheme.space6,
              children: [
                Text(departTime, style: _valueStyle),
                const Text('→', style: _valueStyle),
                Text(arriveTime, style: _valueStyle),
              ],
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildFare(
    ColorScheme cs,
    RailTrainStop? userOriginStop,
    RailTrainStop? userDestStop,
    bool showUserSegment,
    bool isFullRun,
  ) {
    final runOrigin = stops.first;
    final runDest = stops.last;

    return FarePreferenceBuilder(
      builder: (context, fareType) {
        final i18n = AppI18n.of(context);
        final userResolved = userFare?.resolve(fareType);
        final fullResolved = fullFare?.resolve(fareType);
        final useUserFare = showUserSegment && userResolved != null;
        final primary = useUserFare ? userResolved : fullResolved;
        final primaryLabel = useUserFare
            ? '${userOriginStop!.name} → ${userDestStop!.name}'
            : i18n.railRunPair(runOrigin.name, runDest.name);

        // A second figure never appears without saying what it prices — that
        // ambiguity (an unlabelled full-run fare beside a list that already
        // quoted the segment fare) is the P0 bug this screen used to have.
        Widget? secondary;
        if (useUserFare && !isFullRun && fullResolved != null) {
          secondary = Text(
            '${i18n.railFullRunInline(runOrigin.name, runDest.name)}'
            '\$${fullResolved.price}',
            style: AppTextStyles.bodySmall.copyWith(
              color: cs.onSurfaceVariant,
            ),
          );
        } else if (!useUserFare && showUserSegment && !isFullRun) {
          // Wanted the user's segment fare but it failed to resolve (the RPC
          // is best-effort) — say so rather than silently substituting the
          // full-run number unlabelled.
          secondary = Text(
            i18n.railNoFareForPair(userOriginStop!.name, userDestStop!.name),
            style: AppTextStyles.bodySmall.copyWith(
              color: cs.onSurfaceVariant,
            ),
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: AppTheme.space12,
          children: [
            Text(
              AppI18n.of(context).railFareInfo,
              style: AppTextStyles.heading2.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
            AppCard.outlined(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: AppTheme.space4,
                children: [
                  Text(
                    primaryLabel,
                    style: AppTextStyles.bodySmall.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                  if (primary == null)
                    Text(
                      AppI18n.of(context).railNoFare,
                      style: AppTextStyles.bodyRegular.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    )
                  else
                    FareAmount(fare: primary, requested: fareType),
                  if (secondary != null) ...[
                    Divider(
                      height: 1,
                      thickness: 0.5,
                      color: cs.outlineVariant,
                    ),
                    secondary,
                  ],
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}
