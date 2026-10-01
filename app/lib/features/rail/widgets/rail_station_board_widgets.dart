part of '../view/rail_station_detail_view.dart';

/// The board's four outcomes. Two of them look like "nothing to show" and mean
/// very different things: a landed day whose trains have all gone is an answer,
/// a day that was never landed is a gap in the data.
class _BoardBody extends StatelessWidget {
  const _BoardBody({required this.system});

  final RailSystem system;

  @override
  Widget build(BuildContext context) =>
      BlocBuilder<RailStationBoardBloc, RailStationBoardState>(
        builder: (context, state) => switch (state) {
          RailStationBoardLoading() => _BoardSkeleton(system: system),
          RailStationBoardLoaded(:final departures) when departures.isEmpty =>
            _DayOverView(system: system, direction: state.direction),
          RailStationBoardLoaded(
            :final departures,
            :final delays,
            :final delaysUpdatedAt,
          ) =>
            _BoardList(
              system: system,
              departures: departures,
              delays: delays,
              delaysUpdatedAt: delaysUpdatedAt,
            ),
          RailStationBoardFailure(error: NotFoundError()) => _NotLandedView(
            system: system,
          ),
          RailStationBoardFailure(:final error) => ErrorStateView(
            error: error,
            onRetry: () => context.read<RailStationBoardBloc>().add(
              RailStationBoardRequested(state.direction),
            ),
          ),
        },
      );
}

class _BoardList extends StatelessWidget {
  const _BoardList({
    required this.system,
    required this.departures,
    required this.delays,
    required this.delaysUpdatedAt,
  });

  final RailSystem system;
  final List<RailStationDeparture> departures;
  final Map<String, int> delays;

  /// When the delays last landed. Null for THSR, which has no delay feed —
  /// and its board is landed timetable, which does not go stale mid-day.
  final DateTime? delaysUpdatedAt;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // The board is topped up from the next service date when the requested one
    // runs out, so the first row's date is the one everything above the break
    // belongs to.
    final today = departures.first.serviceDate;
    final firstTomorrow = departures.indexWhere((d) => d.serviceDate != today);

    // Only TRA carries live delays, so only its board owes the rider the
    // caveat that they lag the platform displays.
    final notice = system == RailSystem.tra;

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(
        AppTheme.space8,
        AppTheme.space8,
        AppTheme.space8,
        AppTheme.space8,
      ),
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: departures.length + (notice ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == departures.length) {
          return _BoardLiveNotice(delaysUpdatedAt: delaysUpdatedAt);
        }
        final departure = departures[index];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (index > 1 && index != firstTomorrow)
              Divider(
                height: 1,
                thickness: 1,
                indent: 16,
                endIndent: 16,
                color: cs.outlineVariant.withValues(alpha: 0.4),
              ),
            if (index == firstTomorrow) const _NextDayBreak(),
            _DepartureRow(
              system: system,
              departure: departure,
              delayMinutes: delays[departure.trainNo] ?? 0,
              highlighted: index == 0,
            ),
          ],
        );
      },
    );
  }
}

class _BoardLiveNotice extends StatelessWidget {
  const _BoardLiveNotice({required this.delaysUpdatedAt});

  final DateTime? delaysUpdatedAt;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      AppTheme.space16,
      AppTheme.space16,
      AppTheme.space16,
      AppTheme.space8,
    ),
    child: Column(
      children: [
        Text(
          AppI18n.of(context).railBoardLiveNotice,
          textAlign: TextAlign.center,
          style: AppTextStyles.bodySmall.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        // Directly under the lag disclaimer: the two say the same kind of
        // thing — how far behind the platform this board might be — and the
        // stamp is the half that carries a number.
        if (delaysUpdatedAt != null) ...[
          const SizedBox(height: AppTheme.space4),
          FreshnessStamp(at: delaysUpdatedAt),
        ],
      ],
    ),
  );
}

/// Marks where the board crosses midnight into the next service date.
class _NextDayBreak extends StatelessWidget {
  const _NextDayBreak();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppTheme.space8,
        AppTheme.space16,
        AppTheme.space8,
        AppTheme.space8,
      ),
      child: Row(
        children: [
          Text(
            AppI18n.of(context).railBoardNextDay,
            style: AppTextStyles.bodySmall.copyWith(
              color: cs.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: AppTheme.space10),
          Expanded(child: Container(height: 1, color: cs.outlineVariant)),
        ],
      ),
    );
  }
}

/// One departure: the time to scan, where the train goes, and what it is.
class _DepartureRow extends StatelessWidget {
  const _DepartureRow({
    required this.system,
    required this.departure,
    required this.delayMinutes,
    required this.highlighted,
  });

  final RailSystem system;
  final RailStationDeparture departure;
  final int delayMinutes;
  final bool highlighted;

  /// `HH:mm:ss` on the wire; the board shows `HH:mm`, because a departure
  /// board that quotes seconds is quoting precision the timetable doesn't have.
  static String _hhmm(String time) =>
      time.length >= 5 ? time.substring(0, 5) : time;

  void _open(BuildContext context) {
    unawaited(
      // `/rail/train/...` sits outside the shell, so the train screen lands on
      // the root navigator as a full page rather than inside the sheet's box.
      context.push(
        AppRoutes.railTrain(
          departure.trainNo,
          system: system,
          date: DateTime.tryParse(departure.serviceDate),
        ),
        extra: RailTrainExtra(
          delayMinutes: delayMinutes,
          remark: departure.remark,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final i18n = AppI18n.of(context);
    final cs = Theme.of(context).colorScheme;
    final scaler = MediaQuery.textScalerOf(context);
    final suspended = departure.isSuspended;

    return Pressable(
      onTap: suspended ? null : () => _open(context),
      semanticLabel: i18n.towards(departure.destination),
      child: Container(
        // Margin + padding sum to 16 either side highlighted or not, so the
        // tint insets without shifting the row off the content column — the
        // same arithmetic EtaListTile's coming-soon highlight uses.
        margin: highlighted
            ? const EdgeInsets.symmetric(
                horizontal: AppTheme.space8,
                vertical: AppTheme.space4,
              )
            : EdgeInsets.zero,
        decoration: highlighted
            ? BoxDecoration(
                color: AppTheme.surfaceHighlight(cs.brightness),
                borderRadius: BorderRadius.circular(AppTheme.radiusCard),
              )
            : null,
        padding: EdgeInsets.symmetric(
          horizontal: highlighted ? AppTheme.space8 : AppTheme.space16,
          vertical: AppTheme.space10,
        ),
        constraints: BoxConstraints(minHeight: scaler.scale(56)),
        child: Row(
          children: [
            SizedBox(
              width: scaler.scale(62),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _hhmm(departure.departureTime),
                    style: AppTextStyles.timeValue(
                      size: 19,
                      weight: highlighted ? FontWeight.w600 : FontWeight.w400,
                      color: suspended
                          ? AppTheme.inkTertiary(cs.brightness)
                          : cs.onSurface,
                      decoration: suspended ? TextDecoration.lineThrough : null,
                    ),
                  ),
                  if (highlighted && !suspended)
                    _Countdown(departure: departure),
                ],
              ),
            ),
            const SizedBox(width: AppTheme.space12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    i18n.towards(departure.destination),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTextStyles.bodyRegular.copyWith(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: suspended
                          ? AppTheme.inkTertiary(cs.brightness)
                          : cs.onSurface,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      if (departure.trainType.isNotEmpty) ...[
                        TrainTypeChip(type: departure.trainType, compact: true),
                        const SizedBox(width: 7),
                      ],
                      Flexible(
                        child: Text(
                          departure.trainNo,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTextStyles.timeValue(
                            size: 12,
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (suspended)
              Text(
                i18n.railSuspendedShort,
                style: AppTextStyles.bodySmall.copyWith(
                  color: AppTheme.trainDelay,
                  fontWeight: FontWeight.w600,
                ),
              )
            else if (delayMinutes > 0)
              Text(
                i18n.railDelayMinutes(delayMinutes),
                style: AppTextStyles.timeValue(
                  size: 12.5,
                  weight: FontWeight.w600,
                  color: AppTheme.trainDelay,
                ),
              ),
            if (!suspended) ...[
              const SizedBox(width: AppTheme.space4),
              Icon(
                Icons.chevron_right_rounded,
                size: 18,
                color: cs.outline,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Countdown extends StatefulWidget {
  const _Countdown({required this.departure});

  final RailStationDeparture departure;

  @override
  State<_Countdown> createState() => _CountdownState();
}

class _CountdownState extends State<_Countdown> {
  /// Half a minute: fine enough that the displayed minute is never more than
  /// 30s stale, coarse enough to cost nothing.
  static const _tick = Duration(seconds: 30);

  /// Beyond this the countdown says less than the departure time already does.
  static const _horizon = Duration(hours: 2);

  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(_tick, (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final departure = widget.departure;
    final at = DateTime.tryParse(
      '${departure.serviceDate} ${departure.departureTime}',
    );
    if (at == null) return const SizedBox.shrink();
    final left = at.difference(DateTime.now());
    if (left.isNegative || left > _horizon) return const SizedBox.shrink();
    return Text(
      AppI18n.of(context).railInMinutes(left.inMinutes),
      style: AppTextStyles.timeValue(
        size: 11,
        weight: FontWeight.w600,
        color: Theme.of(context).colorScheme.onSurface,
      ),
    );
  }
}

/// The board's loading state: the loaded [_DepartureRow] over a stand-in
/// train, so nothing jumps when the departures land.
class _BoardSkeleton extends StatelessWidget {
  const _BoardSkeleton({required this.system});

  final RailSystem system;

  static const _rowCount = 6;

  static const _departure = RailStationDeparture(
    trainNo: '0000',
    trainType: '囗囗',
    destination: '囗囗囗',
    departureTime: '00:00:00',
    serviceDate: '',
  );

  @override
  Widget build(BuildContext context) {
    return Skeletonizer(
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(
          AppTheme.space8,
          AppTheme.space8,
          AppTheme.space8,
          AppTheme.space8,
        ),
        physics: const NeverScrollableScrollPhysics(),
        itemCount: _rowCount,
        itemBuilder: (context, index) => _DepartureRow(
          system: system,
          departure: _departure,
          delayMinutes: 0,
          highlighted: false,
        ),
      ),
    );
  }
}

/// The requested day is landed and its trains have all gone.
class _DayOverView extends StatelessWidget {
  const _DayOverView({required this.system, required this.direction});

  final RailSystem system;
  final RailBoardDirection direction;

  @override
  Widget build(BuildContext context) {
    final i18n = AppI18n.of(context);
    final label = system == RailSystem.tra
        ? (direction == RailBoardDirection.forward
              ? i18n.railDirectionForward
              : i18n.railDirectionReverse)
        : (direction == RailBoardDirection.forward
              ? i18n.railDirectionSouthbound
              : i18n.railDirectionNorthbound);
    return _BoardNotice(
      title: i18n.railBoardDayOver(label),
      body: i18n.railBoardDayOverHint,
    );
  }
}

/// The requested day was never landed — a gap in the data, not the end of it.
class _NotLandedView extends StatelessWidget {
  const _NotLandedView({required this.system});

  final RailSystem system;

  @override
  Widget build(BuildContext context) {
    final i18n = AppI18n.of(context);
    return _BoardNotice(
      title: i18n.railBoardNotLanded,
      body: i18n.railBoardNotLandedHint(
        system == RailSystem.tra ? i18n.modeTra : i18n.modeThsr,
      ),
    );
  }
}

/// A headline and one line of explanation, centred in whatever height the
/// sheet detent left. No illustration: the system is type-led and achromatic,
/// and a glyph here would be the only picture on the screen.
class _BoardNotice extends StatelessWidget {
  const _BoardNotice({required this.title, required this.body});

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // Centred in whatever height the detent left, and scrollable when the text
    // scale exceeds it — the same shape ErrorStateView uses, so the sheet's two
    // "nothing to show" screens sit in the same place.
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: constraints.maxHeight.isFinite
                ? constraints.maxHeight
                : 0.0,
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              AppTheme.space32,
              AppTheme.space32,
              AppTheme.space32,
              AppTheme.space48,
            ),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    style: AppTextStyles.bodyLarge.copyWith(
                      fontWeight: FontWeight.w600,
                      color: cs.onSurface,
                    ),
                  ),
                  const SizedBox(height: AppTheme.space8),
                  Text(
                    body,
                    textAlign: TextAlign.center,
                    style: AppTextStyles.bodyRegular.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The origin/destination query, demoted to a secondary action under the
/// board. It cannot be dropped: fares, arrival times and any date other than
/// today only exist on that path.
class _QueryFooter extends StatelessWidget {
  const _QueryFooter({
    required this.system,
    required this.stationId,
    required this.name,
  });

  final RailSystem system;
  final String stationId;
  final String name;

  void _openQuery(BuildContext context) {
    unawaited(
      Navigator.of(context).push(
        PagedSheetRoute<void>(
          scrollConfiguration: const SheetScrollConfiguration(),
          initialOffset: AppSheetSnap.tall,
          snapGrid: const SheetSnapGrid(
            snaps: [AppSheetSnap.peek, AppSheetSnap.tall],
            minFlingSpeed: AppSheetSnap.flingSpeed,
          ),
          builder: (_) => HomeRailQuerySheet(
            preset: RailQueryPreset(
              system: system,
              originName: name,
              originId: stationId,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      AppTheme.space20,
      AppTheme.space8,
      AppTheme.space20,
      AppTheme.space32,
    ),
    child: AppButton.outlined(
      label: AppI18n.of(context).railBoardQueryOd,
      onPressed: () => _openQuery(context),
    ),
  );
}
