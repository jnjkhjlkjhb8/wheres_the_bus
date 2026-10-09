part of '../view/bus_stop_detail_view.dart';

class _StopSheet extends StatelessWidget {
  const _StopSheet();

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: () async {
        context.read<BusStopBloc>().add(const BusStopRetryRequested());
      },
      child: const CustomScrollView(
        physics: AlwaysScrollableScrollPhysics(),
        slivers: [
          _StopBody(),
          SliverPadding(padding: EdgeInsets.only(bottom: 56)),
        ],
      ),
    );
  }
}

class _StopBody extends StatelessWidget {
  const _StopBody();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return BlocBuilder<BusStopBloc, BusStopState>(
      buildWhen: (p, n) =>
          p.status != n.status ||
          p.selectedStationUid != n.selectedStationUid ||
          p.error != n.error ||
          !identical(p.members, n.members) ||
          !identical(p.displays, n.displays),
      builder: (context, state) {
        // Non-loaded states are a single box; loaded rows go through a lazy
        // sliver so only visible tiles are built.
        switch (state.status) {
          case BusStopStatus.loading:
            return const SliverToBoxAdapter(child: _StopSkeletonList());
          case BusStopStatus.empty:
            return SliverToBoxAdapter(
              child: _StopMessage(
                icon: Icons.directions_bus_outlined,
                title: AppI18n.of(context).busStopNoRoutes,
                hint: AppI18n.of(context).busStopNoRoutesHint,
              ),
            );
          case BusStopStatus.error:
            return SliverToBoxAdapter(
              child: ErrorStateView(
                error: state.error ?? const OfflineError(),
                onRetry: () {
                  context.read<BusStopBloc>().add(
                    const BusStopRetryRequested(),
                  );
                },
              ),
            );
          case BusStopStatus.loaded:
            final rows = _rowBuilders(context, state, cs);
            return SliverList.builder(
              itemCount: rows.length,
              itemBuilder: (context, i) => rows[i](),
            );
        }
      },
    );
  }

  /// Flattens the loaded state into per-row thunks. Deferring widget
  /// construction to the sliver's itemBuilder is the point: off-screen rows
  /// cost one closure, not a tile subtree.
  List<Widget Function()> _rowBuilders(
    BuildContext context,
    BusStopState state,
    ColorScheme cs,
  ) {
    // Sorted list + per-stop grouping are derived in the bloc; build only
    // lays them out.
    final arrivals = state.displays;
    final byStation = state.arrivalsByStation;
    final members = state.members;
    final selected = state.selectedStationUid;
    final chipMembers = members
        .where((m) => (byStation[m.stationUid] ?? const []).isNotEmpty)
        .toList();
    final hasFilter = chipMembers.length > 1;
    final visibleMembers = selected == null
        ? members
        : members.where((m) => m.stationUid == selected).toList();
    final showHeaders = hasFilter && selected == null;
    final labels = memberStopLabels(chipMembers, byStation);
    // Member stops with no routes render nothing in the 全部 view — an empty
    // group is noise, and a stack of them reads as a broken screen.
    final groups = [
      for (final m in visibleMembers)
        (m, byStation[m.stationUid] ?? const <BusStopArrivalItem>[]),
    ];
    final visibleGroups = selected == null
        ? groups.where((g) => g.$2.isNotEmpty).toList()
        : groups;

    Widget Function() tile(BusStopArrivalItem a, int i) =>
        () => _EtaChevronTile(
          key: ValueKey(a.itemKey),
          arrival: a,
          highlighted: i == 0 && a.display.isComingSoon,
        );
    Widget divider() => Divider(
      height: 1,
      indent: 16,
      endIndent: 16,
      color: cs.outlineVariant.withValues(alpha: 0.5),
    );

    final flatCount = visibleGroups.fold(0, (n, g) => n + g.$2.length);
    return [
      if (hasFilter) ...[
        () => _StationFilterBar(
          members: chipMembers,
          selectedUid: selected,
          labels: labels,
        ),
        divider,
      ],
      if (members.isEmpty)
        for (final (i, a) in arrivals.indexed) tile(a, i)
      else
        for (final group in visibleGroups) ...[
          if (showHeaders)
            () => _StationSectionHeader(
              label: labels[group.$1.stationUid] ?? group.$1.stationName,
              routeCount: group.$2.length,
            ),
          for (final (i, a) in group.$2.indexed) ...[
            tile(a, i),
            if (i < group.$2.length - 1) divider,
          ],
        ],
      if (members.isNotEmpty && flatCount == 0)
        () => _StopMessage(
          icon: Icons.directions_bus_outlined,
          title: AppI18n.of(context).busStopNoData,
          hint: AppI18n.of(context).busStopNoDataHint,
        ),
    ];
  }
}

class _StationFilterBar extends StatelessWidget {
  const _StationFilterBar({
    required this.members,
    required this.selectedUid,
    required this.labels,
  });
  final List<BusStationMember> members;
  final String? selectedUid;
  final Map<String, String> labels;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(
        AppTheme.space16,
        AppTheme.space4,
        AppTheme.space16,
        AppTheme.space8,
      ),
      child: Row(
        spacing: AppTheme.space8,
        children: [
          _StationChip(
            label: AppI18n.of(context).commonAll,
            selected: selectedUid == null,
            uid: null,
          ),
          for (final m in members)
            _StationChip(
              label: labels[m.stationUid] ?? m.stationName,
              selected: selectedUid == m.stationUid,
              uid: m.stationUid,
            ),
        ],
      ),
    );
  }
}

class _StationChip extends StatelessWidget {
  const _StationChip({
    required this.label,
    required this.selected,
    required this.uid,
  });
  final String label;
  final bool selected;
  final String? uid;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Pressable(
      onTap: () => context.read<BusStopBloc>().add(BusStopStationSelected(uid)),
      child: AnimatedContainer(
        duration: AppMotion.micro,
        curve: AppMotion.easeInOut,
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: AppTheme.space16),
        decoration: BoxDecoration(
          color: selected ? cs.primary : cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: TextStyle(
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            fontSize: 13,
            color: selected ? cs.onPrimary : cs.onSurface,
          ),
        ),
      ),
    );
  }
}

class _StationSectionHeader extends StatelessWidget {
  const _StationSectionHeader({required this.label, required this.routeCount});
  final String label;
  final int routeCount;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppTheme.space16,
        AppTheme.space14,
        AppTheme.space16,
        AppTheme.space6,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTextStyles.bodySmall.copyWith(
                color: cs.onSurfaceVariant,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Text(
            AppI18n.of(context).busRouteCount(routeCount),
            style: AppTextStyles.bodySmall.copyWith(
              color: cs.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _StopMeta extends StatelessWidget {
  const _StopMeta();

  @override
  Widget build(BuildContext context) {
    // The freshness line is the only thing that cares about updatedAt, so it
    // selects that field alone and rebuilds independently of the arrival list.
    return BlocSelector<BusStopBloc, BusStopState, DateTime?>(
      selector: (state) => state.updatedAt,
      builder: (context, updatedAt) => updatedAt == null
          ? Text(
              AppI18n.of(context).busStopFallbackTitle,
              style: AppTextStyles.bodySmall.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            )
          : FreshnessStamp(at: updatedAt),
    );
  }
}

class _StopMessage extends StatelessWidget {
  const _StopMessage({
    required this.icon,
    required this.title,
    required this.hint,
  });
  final IconData icon;
  final String title;
  final String hint;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppTheme.space24,
        AppTheme.space48,
        AppTheme.space24,
        AppTheme.space48,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 40, color: AppTheme.inkTertiary(cs.brightness)),
          const SizedBox(height: AppTheme.space16),
          Text(
            title,
            textAlign: TextAlign.center,
            style: AppTextStyles.bodyLarge.copyWith(
              fontWeight: FontWeight.w600,
              color: cs.onSurface,
            ),
          ),
          const SizedBox(height: AppTheme.space6),
          Text(
            hint,
            textAlign: TextAlign.center,
            style: AppTextStyles.bodySmall.copyWith(color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
