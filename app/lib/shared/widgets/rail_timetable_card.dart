import 'package:flutter/material.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/data/models/rail_timetable_view.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/motion/pressable.dart';
import 'package:wheres_the_bus/shared/widgets/train_type_chip.dart';

/// Summary card for one TRA or THSR timetable result. Consumes a decoded
/// [RailTimetableView]; the backend proto never reaches this widget.
class RailTimetableCard extends StatelessWidget {
  const RailTimetableCard({
    required this.timetable,
    this.delayMinutes = 0,
    this.onTap,
    super.key,
  });

  final RailTimetableView timetable;
  final int delayMinutes;
  final VoidCallback? onTap;

  String get _trainNo => timetable.trainNo;
  String get _trainType => timetable.trainType;
  String get _origin => timetable.originName;
  String get _destination => timetable.destinationName;
  String get _departureTime => _clockTime(timetable.departureTime);
  String get _arrivalTime => _clockTime(timetable.arrivalTime);
  String get _travelTime => timetable.travelTime;

  static String _clockTime(String value) {
    final match = RegExp(r'(?:T|^)(\d{2}:\d{2})').firstMatch(value);
    return match?.group(1) ?? value;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final delayed = delayMinutes > 0;
    return Pressable(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(AppTheme.radiusCard),
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.all(AppTheme.space16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  TrainTypeChip(type: _trainType),
                  const SizedBox(width: AppTheme.space8),
                  Text(_trainNo, style: theme.textTheme.titleSmall),
                  const Spacer(),
                  Text(
                    delayed
                        ? AppI18n.of(context).railDelayMinutes(delayMinutes)
                        : AppI18n.of(context).onTime,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: delayed
                          ? AppTheme.trainDelay
                          : theme.colorScheme.primary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppTheme.space16),
              Row(
                children: [
                  Text(_departureTime, style: theme.textTheme.titleLarge),
                  const SizedBox(width: AppTheme.space8),
                  Expanded(
                    child: Column(
                      children: [
                        Text(_travelTime, style: theme.textTheme.bodySmall),
                        Divider(color: theme.colorScheme.outlineVariant),
                      ],
                    ),
                  ),
                  const SizedBox(width: AppTheme.space8),
                  Text(_arrivalTime, style: theme.textTheme.titleLarge),
                ],
              ),
              const SizedBox(height: AppTheme.space8),
              Text(
                '$_origin → $_destination',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
