part of '../view/bus_stop_detail_view.dart';

class _EtaChevronTile extends StatelessWidget {
  const _EtaChevronTile({
    required this.arrival,
    required this.highlighted,
    super.key,
  });
  final BusStopArrivalItem arrival;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final status = arrival.source.displayStatus;
    final ended =
        status == BusStopDisplayStatus.lastBusPassed ||
        status == BusStopDisplayStatus.notOperating;
    return Row(
      children: [
        Expanded(
          child: EtaListTile.fromDisplay(
            arrival.display,
            highlighted: highlighted,
            muted: ended,
            onTap: () {
              final target = arrival.subRouteUid.isNotEmpty
                  ? arrival.subRouteUid
                  : arrival.display.label;
              unawaited(context.push(AppRoutes.busRoute(target)));
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(right: AppTheme.space12),
          child: Icon(
            Icons.chevron_right_rounded,
            size: 20,
            color: cs.outline,
          ),
        ),
      ],
    );
  }
}
