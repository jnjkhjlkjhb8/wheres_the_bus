part of '../view/metro_station_detail_view.dart';

class _StationDetailSheet extends StatelessWidget {
  const _StationDetailSheet({
    required this.system,
    required this.station,
    this.onClose,
  });

  final String system;
  final MetroMapStation station;

  /// 關閉鈕的回呼；省略時不顯示關閉鈕（第二層 sheet 的關閉由 PagedSheet
  /// 返回手勢處理）。`/metro` 地圖內的站點面板仍會傳入此參數以顯示關閉鈕。
  final VoidCallback? onClose;

  List<String> _lines() =>
      station.id.split('_').map((p) => p.replaceAll(_digits, '')).toList();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final lines = _lines();

    return RefreshIndicator(
      onRefresh: () async {
        context.read<MetroEtaBloc>().add(LoadMetroEta(system, station.id));
      },
      child: ListView(
        // Sizes to the rows it has (capped at the viewport, where it starts
        // scrolling), so the sheet's snap grid can stop at the end of the
        // card instead of dragging blank surface up behind a short one.
        shrinkWrap: true,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(
          AppTheme.space16,
          0,
          AppTheme.space16,
          56,
        ),
        children: [
          Row(
            children: [
              if (onClose == null)
                Pressable(
                  onTap: () => Navigator.of(context).maybePop(),
                  semanticLabel: AppI18n.of(context).commonBack,
                  child: SizedBox(
                    width: 40,
                    height: 40,
                    child: Icon(
                      Icons.arrow_back_ios_new_rounded,
                      size: 18,
                      color: cs.onSurface,
                    ),
                  ),
                ),
              for (final code in station.id.split('_'))
                Padding(
                  padding: const EdgeInsets.only(right: AppTheme.space6),
                  child: _MetroRoundel(code: code),
                ),
              const SizedBox(width: AppTheme.space6),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Semantics(
                      header: true,
                      child: Text(
                        station.name,
                        style: AppTextStyles.heading1,
                      ),
                    ),
                    Text(
                      _stationLineLabel(AppI18n.of(context), station.id),
                      style: AppTextStyles.bodySmall.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              FavoriteToggleButton(
                favorite: _metroFavorite(AppI18n.of(context), station),
              ),
              if (onClose != null)
                Pressable(
                  onTap: onClose,
                  semanticLabel: AppI18n.of(context).commonClose,
                  child: Padding(
                    padding: const EdgeInsets.all(11),
                    child: Icon(
                      Icons.close_rounded,
                      size: 22,
                      color: cs.onSurface,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: AppTheme.space12),
          BlocBuilder<MetroEtaBloc, MetroEtaState>(
            builder: (context, state) {
              final arrivals = state.arrivals
                  .where((a) => lines.contains(a.line))
                  .toList();
              if (state.loading && arrivals.isEmpty) {
                return const _MetroArrivalsSkeleton();
              }
              final staleBanner = state.error != null
                  ? Padding(
                      padding: const EdgeInsets.only(bottom: AppTheme.space8),
                      child: _MetroLiveErrorNotice(error: state.error!),
                    )
                  : null;
              if (arrivals.isEmpty) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ?staleBanner,
                    MetroArrivalsEmpty(
                      schedule: state.schedule,
                      onRetry: () => context.read<MetroEtaBloc>().add(
                        LoadMetroEta(system, station.id),
                      ),
                    ),
                  ],
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  ?staleBanner,
                  for (final a in arrivals) ...[
                    MetroArrivalTile(
                      key: ValueKey('${a.line}:${a.destination}'),
                      arrival: a,
                    ),
                    Divider(
                      height: 20,
                      color: cs.outlineVariant.withValues(alpha: 0.5),
                    ),
                  ],
                  // Under the list rather than over it: the countdowns are
                  // what the rider came for, and the stamp is the footnote
                  // that dates them.
                  FreshnessStamp(at: state.updatedAt),
                ],
              );
            },
          ),
          const SizedBox(height: AppTheme.space8),
          BlocBuilder<MetroEtaBloc, MetroEtaState>(
            // First/last-train data is loaded once and never changes per arrival
            // frame; rebuild only when the schedule itself (or its shimmer
            // condition) changes, not on every live ETA push.
            buildWhen: (p, n) =>
                p.schedule != n.schedule ||
                (p.loading && p.schedule.isEmpty) !=
                    (n.loading && n.schedule.isEmpty),
            builder: (context, state) => MetroScheduleSection(
              schedule: state.schedule,
              loading: state.loading,
            ),
          ),
        ],
      ),
    );
  }
}

Favorite _metroFavorite(AppI18n i18n, MetroMapStation s) => Favorite(
  type: FavoriteType.metroStation,
  refId: s.id,
  title: s.name,
  subtitle: _lineName(i18n, s.id),
);

class MetroArrivalTile extends StatelessWidget {
  const MetroArrivalTile({required this.arrival, super.key});

  final MetroArrival arrival;

  @override
  Widget build(BuildContext context) {
    // No local countdown: metro shows the server estimate as-is, re-synced on
    // each ~15s frame. ≤0 reads as 進站中 via ArrivalDisplay.fromMetro.
    final display = ArrivalDisplay.fromMetro(
      line: arrival.line,
      destination: arrival.destination,
      estimateSeconds: arrival.estimateSeconds,
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        EtaListTile.fromDisplay(
          display,
          leading: TransportIcon(type: _getTransportType(arrival.line)),
          destinationStyle: AppTextStyles.heading2,
          bare: true,
        ),
        const SizedBox(height: AppTheme.space10),
        Row(
          children: [
            Expanded(child: _MetroCongestionStrip(levels: arrival.congestion)),
            if (arrival.supportsAlightReminder)
              _MetroAlightBell(arrival: arrival),
          ],
        ),
      ],
    );
  }
}

class _MetroArrivalsSkeleton extends StatelessWidget {
  const _MetroArrivalsSkeleton();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Skeletonizer(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < 3; i++) ...[
            MetroArrivalTile(
              arrival: MetroArrival(
                line: '',
                destination: BoneMock.chars(4, '囗'),
                estimateSeconds: (i + 1) * 120,
                congestion: const [2, 2, 2, 2, 2, 2],
              ),
            ),
            Divider(
              height: 20,
              color: cs.outlineVariant.withValues(alpha: 0.5),
            ),
          ],
        ],
      ),
    );
  }
}

class _MetroCongestionStrip extends StatelessWidget {
  const _MetroCongestionStrip({required this.levels});

  /// Per-car level (1..3) in car order; empty means the arrival carries no
  /// congestion reading.
  final List<int> levels;

  static Color _levelColor(int level) => switch (level) {
    1 => AppTheme.statusArriving,
    2 => AppTheme.statusApproach,
    3 => AppTheme.etaArriving,
    _ => AppTheme.statusArriving,
  };

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final hasData = levels.isNotEmpty;
    // Absent: a neutral 6-car silhouette so the row still reads as a train.
    final cars = hasData
        ? [for (final level in levels) _levelColor(level)]
        : List<Color>.filled(6, cs.surfaceContainerHighest);
    return Row(
      children: [
        Semantics(
          label: hasData
              ? AppI18n.of(context).metroCrowding
              : AppI18n.of(context).metroCrowdingUnavailable,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (i, color) in cars.reversed.indexed) ...[
                if (i > 0) const SizedBox(width: 3),
                _CongestionCar(color: color, head: i == 0),
              ],
            ],
          ),
        ),
        const SizedBox(width: AppTheme.space8),
        Text(
          hasData
              ? AppI18n.of(context).metroCrowding
              : AppI18n.of(context).metroCrowdingUnavailableShort,
          style: AppTextStyles.bodyVerySmall.copyWith(
            color: cs.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _CongestionCar extends StatelessWidget {
  const _CongestionCar({required this.color, required this.head});

  final Color color;
  final bool head;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 24,
      height: 12,
      decoration: BoxDecoration(
        color: color,
        borderRadius: head
            ? const BorderRadius.horizontal(
                left: Radius.circular(3),
                right: Radius.circular(7),
              )
            : BorderRadius.circular(3),
      ),
    );
  }
}

class _MetroAlightBell extends StatefulWidget {
  const _MetroAlightBell({required this.arrival});

  final MetroArrival arrival;

  @override
  State<_MetroAlightBell> createState() => _MetroAlightBellState();
}

class _MetroAlightBellState extends State<_MetroAlightBell> {
  bool _managing = false;

  void _startPick() {
    context.read<MrtTrackBloc>().add(MrtAlightPickStarted(widget.arrival));
    // Already on the map: the pick state alone is enough, and navigating would
    // throw away the rider's current pan and zoom.
    if (context.findAncestorWidgetOfExactType<MetroScreen>() != null) return;
    // Pushed, not `go`: the rider is picking where to get off from a station
    // detail they opened somewhere else, and `go` would clear the stack they
    // still expect to come back to.
    unawaited(context.push(AppRoutes.metroStation(widget.arrival.stationId)));
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<MrtTrackBloc, MrtTrackBlocState>(
      buildWhen: (p, n) =>
          p.tracks(widget.arrival) != n.tracks(widget.arrival) ||
          p.session != n.session,
      builder: (context, state) {
        final active = state.tracks(widget.arrival);
        final session = state.session;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AlightTrackBell(
              active: active,
              semanticLabel: active
                  ? AppI18n.of(context).alightReminderArmed
                  : AppI18n.of(context).alightReminderSet,
              onTap: () {
                if (active) {
                  setState(() => _managing = !_managing);
                } else {
                  _startPick();
                }
              },
            ),
            if (active && _managing && session != null)
              Padding(
                padding: const EdgeInsets.only(top: AppTheme.space8),
                child: AlightManageBar(
                  targetName: session.targetStationName,
                  lead: session.leadStops,
                  onClose: () => setState(() => _managing = false),
                  onCancel: () {
                    context.read<MrtTrackBloc>().add(const MrtTrackCancelled());
                    setState(() => _managing = false);
                  },
                ),
              ),
          ],
        );
      },
    );
  }
}
