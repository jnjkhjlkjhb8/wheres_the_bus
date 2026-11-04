part of '../view/bus_stop_detail_view.dart';

class _StopSkeletonList extends StatelessWidget {
  const _StopSkeletonList();

  @override
  Widget build(BuildContext context) {
    return Skeletonizer(
      child: Column(
        children: [
          for (var i = 0; i < 4; i++)
            EtaListTile(
              routeNo: BoneMock.chars(3, '囗'),
              destination: BoneMock.chars(i.isEven ? 5 : 4, '囗'),
              // One digit each, so every row's status bone is the same width.
              status: EtaStatus.minutes(3 + i),
            ),
        ],
      ),
    );
  }
}
