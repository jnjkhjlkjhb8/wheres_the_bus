import 'package:flutter/material.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/shared/widgets/train_type_chip.dart';

/// A 30px station departure row used in rail timetable lists.
class StationTimetableRow extends StatelessWidget {
  const StationTimetableRow({
    required this.time,
    required this.trainType,
    required this.destination,
    this.platform,
    super.key,
  });

  final String time;
  final String trainType;
  final String destination;
  final String? platform;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 30,
    child: Row(
      children: [
        SizedBox(
          width: 42,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(time, style: Theme.of(context).textTheme.bodySmall),
          ),
        ),
        TrainTypeChip(type: trainType),
        const SizedBox(width: AppTheme.space8),
        Expanded(
          child: Text(
            destination,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        if (platform != null)
          Flexible(
            child: Text(
              platform!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelMedium,
            ),
          ),
      ],
    ),
  );
}
