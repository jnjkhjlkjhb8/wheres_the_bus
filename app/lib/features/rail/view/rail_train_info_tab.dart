part of 'rail_train_screen.dart';

// Public only so tests can mount the tab from stop fixtures instead of the
// whole train screen.
class RailTrainInfoTab extends StatelessWidget {
  const RailTrainInfoTab({
    required this.type,
    required this.trainNo,
    required this.stops,
    required this.fullFare,
    required this.userFare,
    this.userOrigin,
    this.userDest,
    this.marks = const [],
    this.remark = '',
    super.key,
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

    final userOriginStop = _userStop(userOrigin);
    final userDestStop = _userStop(userDest);
    final showUserSegment = userOriginStop != null && userDestStop != null;
    final isFullRun = _isFullRun(userOriginStop, userDestStop);

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
          if (_fareAvailable())
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

  RailTrainStop? _userStop(String? name) =>
      name == null ? null : _findStop(name);

  bool _fareAvailable() => userFare != null || fullFare != null;

  bool _isFullRun(RailTrainStop? origin, RailTrainStop? destination) {
    if (origin == null || destination == null) return true;
    return origin.name == stops.first.name &&
        destination.name == stops.last.name;
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
    final headlineOrigin = _headlineStop(
      showUserSegment,
      userOriginStop,
      runOrigin,
    );
    final headlineDest = _headlineStop(showUserSegment, userDestStop, runDest);

    final departTime = _departureTime(headlineOrigin);
    final arriveTime = _arrivalTime(headlineDest);

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

  RailTrainStop _headlineStop(
    bool showUser,
    RailTrainStop? user,
    RailTrainStop run,
  ) => showUser ? user! : run;

  String _departureTime(RailTrainStop stop) =>
      hhmm(stop.depart.isNotEmpty ? stop.depart : stop.arrive);

  String _arrivalTime(RailTrainStop stop) =>
      hhmm(stop.arrive.isNotEmpty ? stop.arrive : stop.depart);

  Widget _buildFare(
    ColorScheme cs,
    RailTrainStop? userOriginStop,
    RailTrainStop? userDestStop,
    bool showUserSegment,
    bool isFullRun,
  ) {
    return FarePreferenceBuilder(
      builder: (context, fareType) {
        final i18n = AppI18n.of(context);
        final userResolved = userFare?.resolve(fareType);
        final fullResolved = fullFare?.resolve(fareType);
        final useUserFare = _useUserFare(showUserSegment, userResolved);
        final primary = useUserFare ? userResolved : fullResolved;
        final primaryLabel = _primaryFareLabel(
          i18n,
          useUserFare,
          userOriginStop,
          userDestStop,
        );

        // A second figure never appears without saying what it prices — that
        // ambiguity (an unlabelled full-run fare beside a list that already
        // quoted the segment fare) is the P0 bug this screen used to have.
        final secondary = _secondaryFare(
          context,
          useUserFare,
          showUserSegment,
          isFullRun,
          userOriginStop,
          userDestStop,
          fullResolved,
        );

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

  bool _useUserFare(bool showUser, ResolvedFare? fare) =>
      showUser && fare != null;

  String _primaryFareLabel(
    AppI18n i18n,
    bool useUser,
    RailTrainStop? origin,
    RailTrainStop? destination,
  ) => useUser
      ? '${origin!.name} → ${destination!.name}'
      : i18n.railRunPair(stops.first.name, stops.last.name);

  Widget? _secondaryFare(
    BuildContext context,
    bool useUserFare,
    bool showUserSegment,
    bool isFullRun,
    RailTrainStop? userOriginStop,
    RailTrainStop? userDestStop,
    ResolvedFare? fullResolved,
  ) {
    if (isFullRun) return null;
    if (useUserFare) return _fullRunFare(context, fullResolved);
    return _unpricedSegment(
      context,
      showUserSegment,
      userOriginStop,
      userDestStop,
    );
  }

  Widget? _fullRunFare(BuildContext context, ResolvedFare? fare) {
    if (fare == null) return null;
    final label = AppI18n.of(context).railFullRunInline(
      stops.first.name,
      stops.last.name,
    );
    return Text(
      '$label\$${fare.price}',
      style: AppTextStyles.bodySmall.copyWith(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }

  Widget? _unpricedSegment(
    BuildContext context,
    bool showUser,
    RailTrainStop? origin,
    RailTrainStop? destination,
  ) {
    if (!showUser) return null;
    // Keep unresolved segment fares distinct from the full-run price.
    return Text(
      AppI18n.of(context).railNoFareForPair(origin!.name, destination!.name),
      style: AppTextStyles.bodySmall.copyWith(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }
}
