part of '../view/rail_screen.dart';

class _TimetableSkeleton extends StatelessWidget {
  const _TimetableSkeleton();

  /// Enough rows to fill a phone viewport under the context bar; fewer would
  /// leave the page half empty and then fill in.
  static const _rowCount = 7;

  /// One train's worth of stand-in values, on the widths a real row uses.
  static const _RailRow _row = (
    type: '囗囗',
    number: '000',
    delay: 0,
    depart: '00:00',
    arrive: '00:00',
    duration: '0時00分',
    marks: <RailServiceMark>[],
    remark: '',
    isSuspended: false,
    isAddedService: false,
  );

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      children: [
        const _TimetableHeader(),
        Skeletonizer(
          child: Column(
            children: [
              for (var i = 0; i < _rowCount; i++) ...[
                if (i > 0)
                  Divider(
                    height: 1,
                    thickness: 1,
                    indent: 16,
                    color: cs.outlineVariant.withValues(alpha: 0.4),
                  ),
                const _TrainRow(
                  row: _row,
                  system: RailSystem.tra,
                  date: '',
                  origin: '',
                  destination: '',
                  isNext: false,
                  minutesUntil: null,
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
